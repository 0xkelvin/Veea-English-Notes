-- +goose Up
-- TRD 11: verified one-time Apple App Store non-consumable Pro purchases.
-- Stored separately from entitlement_grants so lifetime purchases never collide with the 366-day
-- manual grant constraint or overwrite/revoke independent staff grants.
--
-- All account-owned payment rows are explicitly removed by the account purge.
-- Apple's signed appAccountToken still fences a different account UUID after deletion.
-- This app performs no automatic token transfer; no lifetime tombstone is needed.
-- Apple environments are separate namespaces: sandbox IDs can never overwrite production.

-- Staging and production billing are isolated at database level, not a client flag.
CREATE TABLE IF NOT EXISTS apple_iap_control (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    environment text NOT NULL CHECK (environment IN ('Sandbox', 'Production'))
);
INSERT INTO apple_iap_control (singleton, environment) VALUES (true, 'Production') ON CONFLICT (singleton) DO NOTHING;

CREATE TABLE IF NOT EXISTS apple_pro_purchases (
    original_transaction_id text        NOT NULL CHECK (original_transaction_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
    transaction_id          text        NOT NULL CHECK (transaction_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
    user_id                 uuid        NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    app_account_token       uuid        NOT NULL,
    product_id              text        NOT NULL CHECK (product_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'),
    environment             text        NOT NULL CHECK (environment IN ('Sandbox', 'Production')),
    purchased_at            timestamptz NOT NULL,
    revoked_at              timestamptz,
    revocation_reason       integer,
    verified_at             timestamptz NOT NULL DEFAULT now(),
    apple_signed_at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (environment, original_transaction_id),
    UNIQUE (environment, transaction_id),
    CONSTRAINT apple_pro_purchases_owner CHECK (user_id = app_account_token),
    CONSTRAINT apple_pro_purchases_revocation CHECK (
        revoked_at IS NOT NULL OR revocation_reason IS NULL
    )
);

CREATE INDEX IF NOT EXISTS apple_pro_purchases_user
    ON apple_pro_purchases (user_id, purchased_at DESC, original_transaction_id ASC)
;

-- The one definition of "Premium at time t" (TRD 09, TRD 11):
-- - 'infinity' when the account has an active, unrevoked lifetime Apple Pro purchase at p_at;
-- - ends_at when the account has only an active manual grant at p_at;
-- - NULL when the account is Free at p_at.
-- Manual grants and Apple Pro purchases are evaluated independently at database time.
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION entitlement_premium_until(p_user uuid, p_at timestamptz) RETURNS timestamptz
LANGUAGE sql STABLE AS $$
    SELECT GREATEST(
        (SELECT ends_at FROM entitlement_grants
         WHERE user_id = p_user AND closed_at IS NULL AND starts_at <= p_at AND p_at < ends_at),
        (SELECT 'infinity'::timestamptz FROM apple_pro_purchases
         WHERE user_id = p_user
           AND environment = (SELECT environment FROM apple_iap_control WHERE singleton)
           AND purchased_at <= p_at AND (revoked_at IS NULL OR p_at < revoked_at)
           AND verified_at > p_at - interval '24 hours'
         LIMIT 1)
    )
$$;
-- +goose StatementEnd
