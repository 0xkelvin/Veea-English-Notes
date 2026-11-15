-- +goose Up
-- TRD 01 section 6.7: transactional email outbox with leases and a bounded send budget.

CREATE TABLE IF NOT EXISTS email_outbox (
    id                    uuid        PRIMARY KEY,
    user_id               uuid        REFERENCES users (id) ON DELETE CASCADE,          -- NULL for signup codes
    challenge_id          uuid        REFERENCES otp_challenges (id) ON DELETE CASCADE,
    to_email              text        NOT NULL,
    template              text        NOT NULL
                          CHECK (template IN ('signup_code', 'login_code', 'reset_code', 'set_password_code',
                                              'password_added', 'password_changed', 'password_reset_done')),
    payload_ciphertext    bytea,                    -- AES-256-GCM, NULLed on every non-pending state
    payload_key_id        smallint,
    status                text        NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending', 'sent', 'failed', 'expired', 'cancelled')),
    send_attempts         int         NOT NULL DEFAULT 0
                          CHECK (send_attempts BETWEEN 0 AND 5),   -- durably reserved provider sends
    last_send_started_at  timestamptz,
    next_attempt_at       timestamptz NOT NULL DEFAULT now(),
    lease_token           uuid,                     -- result writes require a matching, unexpired lease
    lease_expires_at      timestamptz,
    not_after             timestamptz NOT NULL,     -- OTP mail: the challenge expiry, notifications: created_at + 24 h
    provider_message_id   text,
    last_error            text,                     -- provider error class only, never payload
    created_at            timestamptz NOT NULL DEFAULT now(),
    finished_at           timestamptz,
    CONSTRAINT outbox_payload_only_pending CHECK (status = 'pending' OR payload_ciphertext IS NULL)
);

CREATE INDEX IF NOT EXISTS email_outbox_due ON email_outbox (next_attempt_at) WHERE status = 'pending';
