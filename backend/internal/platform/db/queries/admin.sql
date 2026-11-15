-- Queries for user administration (TRD 06). Only identity/accounts writes users; the admin
-- service reads through these and writes through the accounts package.

-- name: CountOtherActiveSuperAdmins :one
-- Guarded recheck (TRD 06 section 4.2). Run only while holding the Super Admin guard (L2s) and
-- the subject's L3 row, so every decreasing transition is serialized before this count.
SELECT count(*) FROM users
WHERE role = 'super_admin' AND status = 'active' AND email_verified_at IS NOT NULL AND id <> @id;

-- name: CountActiveSuperAdmins :one
SELECT count(*) FROM users
WHERE role = 'super_admin' AND status = 'active' AND email_verified_at IS NOT NULL;

-- name: SuspendUser :execrows
-- resume_status takes the pre-update status. The caller holds the row at L3 and has checked it is
-- active or deactivated.
UPDATE users SET status = 'suspended', resume_status = status, suspension_reason = @reason,
    suspension_ticket_ref = @ticket_ref, suspended_by = @actor_id,
    lifecycle_revision = lifecycle_revision + 1, state_changed_at = clock_timestamp(), updated_at = clock_timestamp()
WHERE id = @id AND status IN ('active', 'deactivated');

-- name: ReinstateUser :execrows
-- Restores exactly the saved state. Sessions and proofs are never revived: revoked_at is never
-- cleared and the lifecycle revision moves on.
UPDATE users SET status = resume_status, resume_status = NULL, suspension_reason = NULL,
    suspension_ticket_ref = NULL, suspended_by = NULL,
    lifecycle_revision = lifecycle_revision + 1, state_changed_at = clock_timestamp(), updated_at = clock_timestamp()
WHERE id = @id AND status = 'suspended';

-- name: SetUserRole :execrows
UPDATE users SET role = @role, role_revision = role_revision + 1, role_changed_at = clock_timestamp(),
    updated_at = clock_timestamp()
WHERE id = @id;

-- name: AdminActingSessionLive :one
-- Read revalidation (TRD 06 section 8.3): the acting session and its account, in the read
-- transaction's snapshot. No row means 401.
SELECT u.role FROM sessions s JOIN users u ON u.id = s.user_id
WHERE s.id = @session_id AND s.user_id = @user_id
  AND s.revoked_at IS NULL AND s.access_expires_at > now() AND s.absolute_expires_at > now()
  AND u.status = 'active' AND u.email_verified_at IS NOT NULL;

-- name: AdminListUsers :many
-- Keyset page in created_at DESC, id DESC order. Every filter is optional.
SELECT id, email, status, role, created_at, state_changed_at FROM users
WHERE (sqlc.narg(email)::text IS NULL OR email_normalized = sqlc.narg(email)::text)
  AND (sqlc.narg(email_prefix)::text IS NULL OR email_normalized LIKE sqlc.narg(email_prefix)::text || '%')
  AND (sqlc.narg(role)::text IS NULL OR role = sqlc.narg(role)::text)
  AND (sqlc.narg(status)::text IS NULL OR status = sqlc.narg(status)::text)
  AND (sqlc.narg(after_created_at)::timestamptz IS NULL
       OR (created_at, id) < (sqlc.narg(after_created_at)::timestamptz, sqlc.narg(after_id)::uuid))
ORDER BY created_at DESC, id DESC
LIMIT @page_limit;

-- name: AdminSessionSummary :one
-- Live count uses the TRD 02 section 2.1 predicate. last_seen_at spans retained rows.
SELECT
    count(*) FILTER (WHERE revoked_at IS NULL AND absolute_expires_at > now()
                     AND (refresh_expires_at > now() OR access_expires_at > now()))::bigint AS live_count,
    (count(*) > 0)::boolean AS has_sessions,
    COALESCE(max(last_seen_at), 'epoch'::timestamptz)::timestamptz AS last_seen_at
FROM sessions WHERE user_id = @user_id;

-- name: AdminListLiveSessions :many
SELECT id, device_name, platform, created_at, last_seen_at, refresh_expires_at, absolute_expires_at
FROM sessions
WHERE user_id = @user_id AND revoked_at IS NULL AND absolute_expires_at > now()
  AND (refresh_expires_at > now() OR access_expires_at > now())
ORDER BY last_seen_at DESC, id ASC;

-- name: AcceptedDeletionAt :one
SELECT accepted_at::timestamptz FROM account_operations
WHERE user_id = @user_id AND action = 'delete' AND accepted_at IS NOT NULL
LIMIT 1;

-- name: AdminAuditHistory :many
-- Per-account administrative mutation history (TRD 06 §9a). Only the TRD 06 mutation actions,
-- newest first with the identity column as tie-breaker, and never past the 180-day audit
-- retention even if the cleanup job has not reached a row yet. An empty ticket reference
-- means none (a real one is at least one character). Uses audit_events_target.
SELECT id, occurred_at, action, outcome, actor_user_id, reason,
    COALESCE(metadata->>'ticket_ref', '')::text AS ticket_ref
FROM audit_events
WHERE target_user_id = @target_user_id
  AND action IN ('admin.user.suspend', 'admin.user.reinstate', 'admin.role.change', 'admin.role.bootstrap', 'admin.sessions.revoke')
  AND occurred_at > clock_timestamp() - interval '180 days'
  AND (sqlc.narg(after_occurred_at)::timestamptz IS NULL
       OR (occurred_at, id) < (sqlc.narg(after_occurred_at)::timestamptz, sqlc.narg(after_id)::bigint))
ORDER BY occurred_at DESC, id DESC
LIMIT @page_limit;

-- name: MarkSuperAdminBootstrapped :exec
-- TRD 08: written in the bootstrap transaction (and by any promotion to super_admin, as a
-- backstop). Idempotent; the first time is kept.
INSERT INTO rbac_bootstrap (id, first_bootstrapped_at) VALUES (1, clock_timestamp())
ON CONFLICT (id) DO NOTHING;

-- name: SuperAdminBootstrapped :one
-- admin_super_admin_bootstrapped, read when metrics are scraped.
SELECT EXISTS (SELECT 1 FROM rbac_bootstrap)::boolean AS bootstrapped;
