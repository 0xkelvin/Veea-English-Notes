-- +goose Up
-- TRD 01 sections 6.5 and 6.6: opaque-token sessions and consumed refresh tokens.

CREATE TABLE IF NOT EXISTS sessions (
    id                   uuid        PRIMARY KEY,
    user_id              uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    auth_method          text        NOT NULL
                         CHECK (auth_method IN ('signup_otp', 'signup_password', 'otp', 'password')),
    access_token_hash    bytea       NOT NULL,
    access_expires_at    timestamptz NOT NULL,
    refresh_token_hash   bytea       NOT NULL,
    refresh_expires_at   timestamptz NOT NULL,     -- idle expiry, extended on each rotation
    absolute_expires_at  timestamptz NOT NULL,
    rotation_counter     bigint      NOT NULL DEFAULT 0,
    device_name          text        NOT NULL CHECK (char_length(device_name) BETWEEN 1 AND 64),
    platform             text        NOT NULL CHECK (platform IN ('ios', 'android', 'web', 'other')),
    user_agent           text,
    created_ip           inet,
    last_seen_at         timestamptz NOT NULL DEFAULT now(),
    last_seen_ip         inet,
    created_at           timestamptz NOT NULL DEFAULT now(),
    revoked_at           timestamptz,
    revoked_reason       text
                         CHECK (revoked_reason IN ('logout', 'password_set', 'password_change',
                                                   'password_reset', 'refresh_reuse', 'session_limit',
                                                   'account_inactive'))
);

CREATE UNIQUE INDEX IF NOT EXISTS sessions_access_token_hash_key ON sessions (access_token_hash);
CREATE UNIQUE INDEX IF NOT EXISTS sessions_refresh_token_hash_key ON sessions (refresh_token_hash);
CREATE INDEX IF NOT EXISTS sessions_user_active ON sessions (user_id) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS refresh_tokens_consumed (
    token_hash    bytea       PRIMARY KEY,
    session_id    uuid        NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
    consumed_at   timestamptz NOT NULL,
    retain_until  timestamptz NOT NULL   -- the old token's recorded refresh expiry, read before rotation
);

CREATE INDEX IF NOT EXISTS refresh_tokens_consumed_retain ON refresh_tokens_consumed (retain_until);
