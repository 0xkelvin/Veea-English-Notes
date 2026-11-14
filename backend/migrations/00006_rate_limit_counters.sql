-- +goose Up
-- TRD 01 section 6.9: fixed-window counters. Keys carry an email HMAC or an IP bucket, never a raw email.

CREATE TABLE IF NOT EXISTS rate_limit_counters (
    key           text        NOT NULL,
    window_start  timestamptz NOT NULL,
    count         int         NOT NULL,
    PRIMARY KEY (key, window_start)
);
