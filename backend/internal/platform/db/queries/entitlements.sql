-- Queries for Free/Premium entitlements (TRD 09, TRD 11). Plans are separate from roles.
-- Only the admin service writes manual grants; only the purchases service writes Apple Pro
-- purchases; the TRD 04 purge and cleanup remove/detach them.

-- name: EffectiveEntitlement :one
-- The effective plan at database time, read at request time. One instant for the whole statement.
SELECT CAST(t.at AS timestamptz) AS checked_at,
    CAST(e.until IS NOT NULL AS boolean) AS premium,
    CAST(COALESCE(e.until = 'infinity'::timestamptz, false) AS boolean) AS lifetime,
    CAST(CASE WHEN e.until IS NULL OR e.until = 'infinity'::timestamptz THEN 'epoch'::timestamptz ELSE e.until END AS timestamptz) AS premium_until
FROM (SELECT clock_timestamp() AS at) AS t
CROSS JOIN LATERAL (SELECT entitlement_premium_until(sqlc.arg(user_id)::uuid, t.at) AS until) AS e;

-- name: EntitlementAt :one
-- The effective plan at a given database time (the export snapshot, and boundary tests).
SELECT CAST(e.until IS NOT NULL AS boolean) AS premium,
    CAST(COALESCE(e.until = 'infinity'::timestamptz, false) AS boolean) AS lifetime,
    CAST(CASE WHEN e.until IS NULL OR e.until = 'infinity'::timestamptz THEN 'epoch'::timestamptz ELSE e.until END AS timestamptz) AS premium_until
FROM (SELECT entitlement_premium_until(sqlc.arg(user_id)::uuid, sqlc.arg(at)::timestamptz) AS until) AS e;

-- name: EffectiveManualEntitlement :one
-- The active manual grant at database time, used by admin.ChangePlan so manual grants and Apple
-- Pro purchases stay independent.
SELECT CAST(t.at AS timestamptz) AS checked_at,
    CAST(g.ends_at IS NOT NULL AS boolean) AS premium,
    CAST(COALESCE(g.ends_at, 'epoch') AS timestamptz) AS premium_until
FROM (SELECT clock_timestamp() AS at) AS t
LEFT JOIN entitlement_grants g
    ON g.user_id = sqlc.arg(user_id)::uuid AND g.closed_at IS NULL AND g.starts_at <= t.at AND t.at < g.ends_at;

-- name: CloseOpenEntitlementGrant :execrows
-- Closes the open grant of an account whose user row the caller holds at L3.
UPDATE entitlement_grants
SET closed_at = GREATEST(clock_timestamp(), starts_at), closed_reason = @closed_reason, closed_by = @closed_by,
    close_reason_code = sqlc.narg(close_reason_code), close_ticket_ref = sqlc.narg(close_ticket_ref)
WHERE user_id = @user_id AND closed_at IS NULL;

-- name: PruneEntitlementHistory :exec
-- Keeps at most the given number of closed periods (TRD 09 §4: 50 retained rows per account, counting the one
-- about to be inserted). Oldest periods go first.
DELETE FROM entitlement_grants WHERE id IN (
    SELECT g.id FROM entitlement_grants g
    WHERE g.user_id = sqlc.arg(user_id)::uuid AND g.closed_at IS NOT NULL
    ORDER BY g.period_end DESC, g.id DESC
    OFFSET sqlc.arg(keep)::int);

-- name: InsertEntitlementGrant :exec
INSERT INTO entitlement_grants (id, user_id, plan, source, starts_at, ends_at, granted_by, reason_code, ticket_ref)
VALUES (@id, @user_id, 'premium', 'manual', @starts_at, @ends_at, @granted_by, @reason_code, @ticket_ref);

-- name: ListRetainedEntitlementGrants :many
-- The owner export (TRD 09 §7): retained periods only, newest first, never staff identifiers,
-- reasons or ticket references.
SELECT starts_at, ends_at, closed_at, closed_reason, period_end
FROM entitlement_grants
WHERE user_id = sqlc.arg(user_id)::uuid AND period_end > sqlc.arg(at)::timestamptz - interval '180 days'
ORDER BY starts_at DESC, id DESC
LIMIT sqlc.arg(max_rows)::int;

-- name: CleanupEntitlementGrants :execrows
-- Retention (TRD 09 §4): periods that ended over 180 days ago, one bounded batch.
DELETE FROM entitlement_grants WHERE id IN (
    SELECT g.id FROM entitlement_grants g WHERE g.period_end < clock_timestamp() - interval '180 days'
    ORDER BY g.period_end LIMIT sqlc.arg(batch_size)::int);

-- name: DeleteAccountEntitlementGrants :exec
-- TRD 04 purge step; at most 50 rows per account.
DELETE FROM entitlement_grants WHERE user_id = @user_id;

-- name: LockAppleProPurchaseByOriginalID :one
SELECT * FROM apple_pro_purchases WHERE environment = @environment AND original_transaction_id = @original_transaction_id FOR UPDATE;

-- name: LockAppleProPurchaseByTransactionID :one
SELECT * FROM apple_pro_purchases WHERE environment = @environment AND transaction_id = @transaction_id FOR UPDATE;

-- name: UpsertAppleProPurchase :one
INSERT INTO apple_pro_purchases (
    original_transaction_id, transaction_id, user_id, app_account_token,
    product_id, environment, purchased_at, revoked_at, revocation_reason, verified_at, apple_signed_at
) VALUES (
    @original_transaction_id, @transaction_id, @user_id, @app_account_token,
    @product_id, @environment, @purchased_at, @revoked_at, @revocation_reason, clock_timestamp(), @apple_signed_at
)
ON CONFLICT (environment, original_transaction_id) DO UPDATE SET
    transaction_id    = EXCLUDED.transaction_id,
    product_id        = EXCLUDED.product_id,
    environment       = EXCLUDED.environment,
    purchased_at      = EXCLUDED.purchased_at,
    revoked_at = CASE WHEN EXCLUDED.apple_signed_at > apple_pro_purchases.apple_signed_at
      OR (EXCLUDED.apple_signed_at = apple_pro_purchases.apple_signed_at AND EXCLUDED.revoked_at IS NOT NULL)
      THEN EXCLUDED.revoked_at ELSE apple_pro_purchases.revoked_at END,
    revocation_reason = CASE WHEN EXCLUDED.apple_signed_at > apple_pro_purchases.apple_signed_at
      OR (EXCLUDED.apple_signed_at = apple_pro_purchases.apple_signed_at AND EXCLUDED.revoked_at IS NOT NULL)
      THEN EXCLUDED.revocation_reason ELSE apple_pro_purchases.revocation_reason END,
    apple_signed_at = GREATEST(apple_pro_purchases.apple_signed_at,EXCLUDED.apple_signed_at),
    verified_at       = clock_timestamp()
RETURNING *;

-- name: ListAccountApplePurchases :many
-- The owner export (TRD 11): product metadata and timestamps only, bounded by max_rows.
SELECT product_id, environment, purchased_at, revoked_at
FROM apple_pro_purchases
WHERE user_id = sqlc.arg(user_id)::uuid
ORDER BY purchased_at DESC, original_transaction_id ASC
LIMIT sqlc.arg(max_rows)::int;

-- name: PurgeAccountApplePurchases :exec
DELETE FROM apple_pro_purchases WHERE user_id = @user_id;

-- name: ListApplePurchasesForVerification :many
SELECT transaction_id, environment, verified_at, revoked_at FROM apple_pro_purchases
WHERE user_id = @user_id
ORDER BY environment, original_transaction_id;

-- name: PruneAccountApplePurchases :exec
-- Keep five recent ownership proofs. Older purchases can be restored from Apple,
-- whose account token, rather than a retained database tombstone, fences ownership.
DELETE FROM apple_pro_purchases WHERE user_id = sqlc.arg(user_id)::uuid AND (environment, original_transaction_id) IN (
    SELECT environment, original_transaction_id FROM apple_pro_purchases
    WHERE user_id = sqlc.arg(user_id)::uuid
    ORDER BY purchased_at DESC, environment, original_transaction_id
    OFFSET 5
);

-- name: AppleIAPEnvironment :one
SELECT environment FROM apple_iap_control WHERE singleton;
