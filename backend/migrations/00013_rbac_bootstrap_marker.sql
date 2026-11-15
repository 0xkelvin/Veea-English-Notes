-- +goose Up
-- TRD 08: a durable "Super Admin bootstrap has happened" marker, so monitoring can tell a fresh
-- deployment (no Super Admin yet, expected) from one that lost its last active Super Admin.
-- One row at most. Not user-owned: it holds no account identifier and survives every purge.
CREATE TABLE IF NOT EXISTS rbac_bootstrap (
    id                    smallint    PRIMARY KEY CHECK (id = 1),
    first_bootstrapped_at timestamptz NOT NULL
);

-- Backfill for databases that were bootstrapped before this version: any Super Admin row, or a
-- bootstrap event still inside audit retention, proves it happened.
INSERT INTO rbac_bootstrap (id, first_bootstrapped_at)
SELECT 1, COALESCE((SELECT min(occurred_at) FROM audit_events WHERE action = 'admin.role.bootstrap'), now())
WHERE EXISTS (SELECT 1 FROM users WHERE role = 'super_admin')
   OR EXISTS (SELECT 1 FROM audit_events WHERE action = 'admin.role.bootstrap')
ON CONFLICT (id) DO NOTHING;
