---
description: "Use when creating SQL migrations, modifying database schema, or working with SQLx migrations in the migrations/ directory."
applyTo: "migrations/**"
---
# SQL Migration Conventions

## File Naming

- Format: `YYYYMMDDHHMMSS_description.sql` (e.g. `20250101000001_create_users.sql`).
- Use `make migrate-add name=create_foo` to generate new migration files.

## Schema Patterns

- Primary keys: `UUID` type, application-generated (not serial).
- Timestamps: `TIMESTAMPTZ NOT NULL DEFAULT now()`.
- JSON columns: `JSONB NOT NULL DEFAULT '{}'`.
- Nullable timestamps for optional fields: `revoked_at TIMESTAMPTZ` (no default).
- Use `TEXT` for string columns (not VARCHAR) — Postgres treats them identically.
- Foreign keys: `REFERENCES parent(id) ON DELETE CASCADE`.

## Indexes

- Always index foreign keys and frequently queried columns.
- Use partial indexes for status-based queries:

```sql
CREATE INDEX idx_outbox_events_pending
    ON outbox_events (occurred_at ASC)
    WHERE status = 'pending';
```

## Constraints

- Unique constraints: `CONSTRAINT uq_<table>_<column> UNIQUE (<column>)`.
- Composite primary keys for join/inbox tables: `PRIMARY KEY (col_a, col_b)`.

## Safety

- Always use `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS`.
- Migrations run automatically on startup via `sqlx::migrate!("./migrations")`.
- Never drop columns in the same release as code removal.
