-- Queries for Free/Premium entitlements (TRD 09). Plans are separate from roles. Only the admin
-- service writes grants; the TRD 04 purge and cleanup delete them.

-- name: EffectiveEntitlement :one
-- The effective plan at database time, read at request time. One instant for the whole statement.
SELECT CAST(t.at AS timestamptz) AS checked_at,
    CAST(e.until IS NOT NULL AS boolean) AS premium,
    CAST(COALESCE(e.until, 'epoch') AS timestamptz) AS premium_until
FROM (SELECT clock_timestamp() AS at) AS t
CROSS JOIN LATERAL (SELECT entitlement_premium_until(sqlc.arg(user_id)::uuid, t.at) AS until) AS e;

-- name: EntitlementAt :one
-- The effective plan at a given database time (the export snapshot, and boundary tests).
SELECT CAST(e.until IS NOT NULL AS boolean) AS premium,
    CAST(COALESCE(e.until, 'epoch') AS timestamptz) AS premium_until
FROM (SELECT entitlement_premium_until(sqlc.arg(user_id)::uuid, sqlc.arg(at)::timestamptz) AS until) AS e;

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
