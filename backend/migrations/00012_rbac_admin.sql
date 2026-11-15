-- +goose Up
-- TRD 06: RBAC and user administration. Expand-only. Run through cmd/migrate before the binaries.

-- Role changes carry their own revision so a retried admin request cannot undo a later change.
ALTER TABLE users ADD COLUMN IF NOT EXISTS role_revision bigint NOT NULL DEFAULT 0 CHECK (role_revision >= 0);
ALTER TABLE users ADD COLUMN IF NOT EXISTS role_changed_at timestamptz;

-- Suspension saves the state it interrupted (TRD 04 section 3.2) and its fixed reason.
-- suspended_by deliberately has no FK: it survives the admin's own purge and adds no
-- cross-user cascade locks to the final user delete.
ALTER TABLE users ADD COLUMN IF NOT EXISTS resume_status text CHECK (resume_status IN ('active', 'deactivated'));
ALTER TABLE users ADD COLUMN IF NOT EXISTS suspension_reason text CHECK (suspension_reason ~ '^[a-z_]{1,40}$');
ALTER TABLE users ADD COLUMN IF NOT EXISTS suspension_ticket_ref text
    CHECK (suspension_ticket_ref ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$');
ALTER TABLE users ADD COLUMN IF NOT EXISTS suspended_by uuid;

-- No code produced 'suspended' before this version. Backfill any hand-edited row before constraining.
UPDATE users SET resume_status = 'active', suspension_reason = 'other'
WHERE status = 'suspended' AND (resume_status IS NULL OR suspension_reason IS NULL);
UPDATE users SET resume_status = NULL, suspension_reason = NULL, suspension_ticket_ref = NULL, suspended_by = NULL
WHERE status <> 'suspended' AND (resume_status IS NOT NULL OR suspension_reason IS NOT NULL);
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_suspension_state,
    ADD CONSTRAINT users_suspension_state CHECK (
        (status = 'suspended') = (resume_status IS NOT NULL)
        AND (status = 'suspended') = (suspension_reason IS NOT NULL)
        AND (status = 'suspended' OR (suspension_ticket_ref IS NULL AND suspended_by IS NULL)));

ALTER TABLE sessions DROP CONSTRAINT IF EXISTS sessions_revoked_reason_check,
    ADD CONSTRAINT sessions_revoked_reason_check CHECK (revoked_reason IN (
        'logout', 'password_set', 'password_change', 'password_reset', 'refresh_reuse', 'session_limit',
        'account_inactive', 'user_revoked', 'logout_all', 'email_change', 'deactivated', 'account_delete',
        'admin_revoked', 'account_suspended', 'role_change'));

-- Admin listing (keyset on created_at, id), email prefix search and the Super Admin guard count.
CREATE INDEX IF NOT EXISTS users_admin_order ON users (created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS users_email_pattern ON users (email_normalized text_pattern_ops);
CREATE INDEX IF NOT EXISTS users_active_super_admins ON users (id) WHERE role = 'super_admin' AND status = 'active';
