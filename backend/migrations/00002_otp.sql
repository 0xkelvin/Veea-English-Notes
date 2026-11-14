-- +goose Up
-- TRD 01 sections 6.3 and 6.4: OTP challenges and the per (purpose, email) resend cooldown.

CREATE TABLE IF NOT EXISTS otp_challenges (
    id                     uuid        PRIMARY KEY,
    token_hash             bytea       NOT NULL,   -- SHA-256 of the vct_ challenge token
    purpose                text        NOT NULL
                           CHECK (purpose IN ('signup', 'login', 'password_reset', 'set_password')),
    signup_method          text        CHECK (signup_method IN ('otp', 'password')),
    pending_password_hash  text,                   -- password signup only, NULLed on every terminal state
    email                  text        NOT NULL,   -- as entered, used for the account row on signup
    email_normalized       text        NOT NULL,
    user_id                uuid        REFERENCES users (id) ON DELETE CASCADE,
    session_id             uuid,                   -- set_password only, deliberately no foreign key
    code_hash              bytea       NOT NULL,   -- HMAC-SHA256(otp_key, id || code)
    delivery               text        NOT NULL CHECK (delivery IN ('code', 'none')),
    attempts               int         NOT NULL DEFAULT 0,
    max_attempts           int         NOT NULL,
    created_at             timestamptz NOT NULL DEFAULT now(),
    expires_at             timestamptz NOT NULL,
    consumed_at            timestamptz,
    superseded_at          timestamptz,
    request_ip             inet,
    CONSTRAINT otp_signup_method CHECK ((purpose = 'signup') = (signup_method IS NOT NULL)),
    -- Corrected from the TRD text: with a NULL signup_method the TRD form
    -- (signup_method = 'password') evaluates to NULL, which a CHECK accepts. IS NOT DISTINCT FROM
    -- makes that case false, so only password signups can hold a pending hash.
    CONSTRAINT otp_pending_pw CHECK (pending_password_hash IS NULL
                                     OR signup_method IS NOT DISTINCT FROM 'password'),
    -- delivery = 'none' challenges are inert: never consumed, never bound to an account or credential.
    CONSTRAINT otp_none_inert CHECK (delivery = 'code'
                                     OR (consumed_at IS NULL AND user_id IS NULL
                                         AND session_id IS NULL AND pending_password_hash IS NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS otp_challenges_token_hash_key ON otp_challenges (token_hash);

-- At most one open challenge per purpose and email. Backstop for the start transaction.
CREATE UNIQUE INDEX IF NOT EXISTS otp_challenges_one_open
    ON otp_challenges (purpose, email_normalized)
    WHERE consumed_at IS NULL AND superseded_at IS NULL;

CREATE INDEX IF NOT EXISTS otp_challenges_expires ON otp_challenges (expires_at);

CREATE TABLE IF NOT EXISTS otp_cooldowns (
    purpose         text        NOT NULL,
    email_hmac      bytea       NOT NULL,          -- HMAC(email_key, email_normalized), no raw email
    last_issued_at  timestamptz NOT NULL,
    PRIMARY KEY (purpose, email_hmac)
);
