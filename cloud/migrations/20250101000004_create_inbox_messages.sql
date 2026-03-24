-- Create inbox_messages table for idempotent consumer pattern
CREATE TABLE IF NOT EXISTS inbox_messages (
    message_id    TEXT        NOT NULL,
    consumer_name TEXT        NOT NULL,
    processed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (message_id, consumer_name)
);
