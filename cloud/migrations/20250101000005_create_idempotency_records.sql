-- Create idempotency_records table for HTTP request deduplication
CREATE TABLE IF NOT EXISTS idempotency_records (
    id              UUID        PRIMARY KEY,
    idempotency_key TEXT        NOT NULL,
    request_hash    TEXT        NOT NULL,
    response_status INT         NOT NULL,
    response_body   JSONB       NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_idempotency_key UNIQUE (idempotency_key)
);

-- TTL cleanup: periodically delete records older than 24h via cron or scheduled task
CREATE INDEX IF NOT EXISTS idx_idempotency_records_created_at
    ON idempotency_records (created_at);
