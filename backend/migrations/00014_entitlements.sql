-- +goose Up
-- TRD 09: manual Premium grants. Plans are separate from RBAC roles. Expand-only.

-- The retry guard for plan changes, separate from lifecycle and role revisions so a plan change
-- never invalidates OTP proofs, rights operations or role retries.
ALTER TABLE users ADD COLUMN IF NOT EXISTS entitlement_revision bigint NOT NULL DEFAULT 0 CHECK (entitlement_revision >= 0);

-- One row per grant period. At most one open row per account. User-owned: the TRD 04 purge
-- deletes the rows explicitly, and RESTRICT makes a purge that forgot them fail closed.
-- granted_by and closed_by are staff identifiers with no FK (they survive a staff purge) and
-- are never exported. Retention: 180 days after period_end, and at most 50 rows per account.
CREATE TABLE IF NOT EXISTS entitlement_grants (
    id                uuid        PRIMARY KEY,
    user_id           uuid        NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    plan              text        NOT NULL CHECK (plan = 'premium'),
    source            text        NOT NULL CHECK (source = 'manual'),
    starts_at         timestamptz NOT NULL,
    ends_at           timestamptz NOT NULL,
    granted_by        uuid        NOT NULL,
    reason_code       text        NOT NULL CHECK (reason_code ~ '^[a-z_]{1,40}$'),
    ticket_ref        text        NOT NULL CHECK (ticket_ref ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'),
    created_at        timestamptz NOT NULL DEFAULT now(),
    closed_at         timestamptz,
    closed_reason     text        CHECK (closed_reason IN ('replaced', 'revoked')),
    closed_by         uuid,
    close_reason_code text        CHECK (close_reason_code ~ '^[a-z_]{1,40}$'),
    close_ticket_ref  text        CHECK (close_ticket_ref ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'),
    period_end        timestamptz GENERATED ALWAYS AS (LEAST(ends_at, COALESCE(closed_at, ends_at))) STORED,
    CONSTRAINT entitlement_grants_period CHECK (ends_at > starts_at AND ends_at <= starts_at + interval '366 days'),
    CONSTRAINT entitlement_grants_closed CHECK (
        (closed_at IS NULL) = (closed_reason IS NULL)
        AND (closed_at IS NULL) = (closed_by IS NULL)
        AND (closed_at IS NULL OR closed_at >= starts_at)
        AND ((closed_reason = 'revoked') = (close_reason_code IS NOT NULL AND close_ticket_ref IS NOT NULL)))
);

CREATE UNIQUE INDEX IF NOT EXISTS entitlement_grants_one_open ON entitlement_grants (user_id) WHERE closed_at IS NULL;
CREATE INDEX IF NOT EXISTS entitlement_grants_owner ON entitlement_grants (user_id, starts_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS entitlement_grants_retention ON entitlement_grants (period_end);

-- The one definition of "Premium at time t", used with database time by the owner read, the
-- admin view and the export snapshot. Expiry is exact: Premium while t < ends_at.
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION entitlement_premium_until(p_user uuid, p_at timestamptz) RETURNS timestamptz
LANGUAGE sql STABLE AS $$
    SELECT ends_at FROM entitlement_grants
    WHERE user_id = p_user AND closed_at IS NULL AND starts_at <= p_at AND p_at < ends_at
$$;
-- +goose StatementEnd
