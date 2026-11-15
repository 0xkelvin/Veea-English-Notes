-- +goose Up
-- TRD 01 section 6.8: append-only audit trail. No foreign keys, so it outlives the user.
-- Restricting the application role to INSERT and SELECT is a deployment grant, not part of this file.

CREATE TABLE IF NOT EXISTS audit_events (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at     timestamptz NOT NULL DEFAULT now(),
    action          text        NOT NULL,
    outcome         text        NOT NULL CHECK (outcome IN ('success', 'failure')),
    reason          text,
    actor_user_id   uuid,
    target_user_id  uuid,
    session_id      uuid,
    email_hmac      bytea,
    ip              inet,
    user_agent      text,
    request_id      text,
    metadata        jsonb       NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS audit_events_target ON audit_events (target_user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_events_action ON audit_events (action, occurred_at DESC);
