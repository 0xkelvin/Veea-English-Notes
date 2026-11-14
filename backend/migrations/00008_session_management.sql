-- +goose Up
-- TRD 02: extend the existing reason constraint without changing retained history.
-- PostgreSQL has no ADD CONSTRAINT IF NOT EXISTS. Replacing the named constraint in one
-- transactional ALTER is replayable and never exposes an unconstrained table to other users.
ALTER TABLE sessions
    DROP CONSTRAINT IF EXISTS sessions_revoked_reason_check,
    ADD CONSTRAINT sessions_revoked_reason_check CHECK (revoked_reason IN (
        'logout', 'password_set', 'password_change', 'password_reset', 'refresh_reuse',
        'session_limit', 'account_inactive', 'user_revoked', 'logout_all'
    ));
