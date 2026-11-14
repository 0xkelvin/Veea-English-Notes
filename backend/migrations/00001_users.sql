-- +goose Up
-- TRD 01 section 6.2. One row per verified account. A pending signup is never a row here.

CREATE TABLE IF NOT EXISTS users (
    id                   uuid        PRIMARY KEY,
    email                text        NOT NULL,
    email_normalized     text        NOT NULL,
    email_verified_at    timestamptz,
    password_hash        text,                    -- PHC string, NULL means no password set
    password_changed_at  timestamptz,             -- informational only
    status               text        NOT NULL DEFAULT 'active'
                         CHECK (status IN ('active', 'suspended', 'deactivated', 'pending_deletion')),
    role                 text        NOT NULL DEFAULT 'user'
                         CHECK (role IN ('user', 'admin', 'super_admin')),
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT users_email_len CHECK (octet_length(email_normalized) <= 254)
);

CREATE UNIQUE INDEX IF NOT EXISTS users_email_normalized_key ON users (email_normalized);
