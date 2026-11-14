-- Queries for sessions and consumed refresh tokens. TRD 01 sections 6.5, 6.6, 7.1, 8.1 and 8.4 to 8.6.

-- name: InsertSession :one
INSERT INTO sessions (
    id, user_id, auth_method, access_token_hash, access_expires_at, refresh_token_hash,
    refresh_expires_at, absolute_expires_at, device_name, platform, user_agent, created_ip, last_seen_ip
) VALUES (
    @id, @user_id, @auth_method, @access_token_hash, @access_expires_at, @refresh_token_hash,
    @refresh_expires_at, @absolute_expires_at, @device_name, @platform, @user_agent, @created_ip, @created_ip
)
RETURNING *;

-- name: AuthenticateAccessToken :one
-- Per-request check (TRD 8.1). One indexed read, no locks. No row means 401.
SELECT s.id AS session_id, s.user_id, u.status, u.role, u.email
FROM sessions s
JOIN users u ON u.id = s.user_id
WHERE s.access_token_hash = @access_token_hash
  AND s.revoked_at IS NULL
  AND s.access_expires_at > now()
  AND s.absolute_expires_at > now()
  AND u.status = 'active'
  AND u.email_verified_at IS NOT NULL;

-- name: GetSessionOwnerStatus :one
-- Distinguishes "user no longer active" from "unknown token" after AuthenticateAccessToken
-- found nothing, so the caller can revoke with reason account_inactive (TRD 8.1).
SELECT s.id AS session_id, s.user_id, s.revoked_at, u.status, u.email_verified_at
FROM sessions s
JOIN users u ON u.id = s.user_id
WHERE s.access_token_hash = @access_token_hash;

-- name: TouchSessionLastSeen :execrows
-- At most one write per session every 5 minutes (TRD 8.1).
UPDATE sessions
SET last_seen_at = now(), last_seen_ip = @last_seen_ip
WHERE id = @id AND last_seen_at < now() - interval '5 minutes';

-- name: LockActingSessionForUpdate :one
-- Lock level L4a (TRD 7.1, 7.5). Locks and re-validates the acting session: scoped to the
-- user, not revoked, not expired. No row means the caller returns 401 and changes nothing.
SELECT * FROM sessions
WHERE id = @id
  AND user_id = @user_id
  AND revoked_at IS NULL
  AND absolute_expires_at > now()
  AND access_expires_at > now()
FOR UPDATE;

-- name: LockSessionByRefreshTokenHash :one
-- Lock level L4a, refresh step 1 (TRD 8.4). Locks only the session row, never users.
-- Under READ COMMITTED a waiter re-evaluates the WHERE against the row version the other
-- transaction committed, so after a rotation the old hash no longer matches and no row returns.
SELECT s.*, u.status AS user_status, u.email_verified_at AS user_email_verified_at
FROM sessions s
JOIN users u ON u.id = s.user_id
WHERE s.refresh_token_hash = @refresh_token_hash
FOR UPDATE OF s;

-- name: RotateSession :execrows
-- Refresh step 2: new token pair on a row locked by LockSessionByRefreshTokenHash.
UPDATE sessions
SET access_token_hash = @access_token_hash,
    access_expires_at = @access_expires_at,
    refresh_token_hash = @refresh_token_hash,
    refresh_expires_at = @refresh_expires_at,
    rotation_counter = rotation_counter + 1,
    last_seen_at = now()
WHERE id = @id AND revoked_at IS NULL;

-- name: InsertConsumedRefreshToken :exec
-- retain_until is the old token's own recorded refresh expiry (TRD 8.5).
INSERT INTO refresh_tokens_consumed (token_hash, session_id, consumed_at, retain_until)
VALUES (@token_hash, @session_id, now(), @retain_until);

-- name: FindConsumedRefreshToken :one
-- Reuse lookup with the retention cutoff enforced (TRD 8.4 step 3). Past retain_until the
-- token is treated as unknown, whether or not cleanup has deleted the row.
SELECT session_id FROM refresh_tokens_consumed
WHERE token_hash = @token_hash AND retain_until > now();

-- name: RevokeSession :execrows
-- Logout, refresh reuse, account_inactive. Idempotent. Scoped by user so one user cannot
-- revoke another user's session by id.
UPDATE sessions
SET revoked_at = now(), revoked_reason = @reason
WHERE id = @id AND user_id = @user_id AND revoked_at IS NULL;

-- name: RevokeSessionByID :execrows
-- For paths that hold only the session id from a token lookup (refresh reuse).
UPDATE sessions
SET revoked_at = now(), revoked_reason = @reason
WHERE id = @id AND revoked_at IS NULL;

-- name: RevokeOtherSessionsForUser :execrows
-- Lock level L4b. Password set and change keep the acting session (TRD 7.5).
UPDATE sessions
SET revoked_at = now(), revoked_reason = @reason
WHERE user_id = @user_id AND id <> @keep_session_id AND revoked_at IS NULL;

-- name: RevokeAllSessionsForUser :execrows
-- Lock level L4b. Password reset revokes every session (TRD 7.5).
UPDATE sessions
SET revoked_at = now(), revoked_reason = @reason
WHERE user_id = @user_id AND revoked_at IS NULL;

-- name: CountActiveSessionsForUser :one
-- Session cap input (TRD 8.6). The use case holds the user lock (L3).
SELECT count(*) FROM sessions
WHERE user_id = @user_id
  AND revoked_at IS NULL
  AND absolute_expires_at > now()
  AND refresh_expires_at > now();

-- name: RevokeSessionsBeyondLimit :execrows
-- Session cap eviction, lock level L4b. Keeps the keep_count most recently seen active
-- sessions and revokes the rest with reason session_limit.
UPDATE sessions
SET revoked_at = now(), revoked_reason = 'session_limit'
WHERE id IN (
    SELECT c.id FROM sessions c
    WHERE c.user_id = @user_id
      AND c.revoked_at IS NULL
      AND c.absolute_expires_at > now()
      AND c.refresh_expires_at > now()
    ORDER BY c.last_seen_at DESC, c.id
    OFFSET @keep_count
);

-- name: DeleteExpiredConsumedRefreshTokens :execrows
-- Cleanup job (TRD 6.10). Correctness does not depend on it: lookup enforces the cutoff.
-- One batch picked through refresh_tokens_consumed_retain and deleted by tuple id (see
-- DeleteOldRateLimitCounters), with the predicate repeated on the outer side.
DELETE FROM refresh_tokens_consumed
WHERE ctid = ANY (ARRAY(
    SELECT ctid FROM refresh_tokens_consumed
    WHERE retain_until <= now()
    LIMIT @batch_size
))
  AND retain_until <= now();

-- name: DeleteStaleSessions :execrows
-- Cleanup job (TRD 6.10): 30 days after revocation or absolute expiry. Cascades to consumed
-- tokens. One batch picked through sessions_revoked_at and sessions_absolute_expires
-- (BitmapOr) and deleted by tuple id (see DeleteOldRateLimitCounters), with the predicate
-- repeated on the outer side.
DELETE FROM sessions
WHERE ctid = ANY (ARRAY(
    SELECT c.ctid FROM sessions c
    WHERE (c.revoked_at IS NOT NULL AND c.revoked_at < now() - interval '30 days')
       OR c.absolute_expires_at < now() - interval '30 days'
    LIMIT @batch_size
))
  AND ((revoked_at IS NOT NULL AND revoked_at < now() - interval '30 days')
       OR absolute_expires_at < now() - interval '30 days');

-- name: FindSessionForRefreshToken :one
-- Refresh pre-check (TRD 8.4, 10), unlocked and before any transaction: the session a refresh
-- token belongs to, as its current token or as a consumed one still within retention. Both
-- branches read one snapshot, so a token being rotated right now is found in one or the other.
-- No row means the token is unknown or past retention: a plain 401, nothing else to do.
SELECT id AS session_id FROM sessions WHERE refresh_token_hash = @token_hash
UNION ALL
SELECT c.session_id FROM refresh_tokens_consumed c
WHERE c.token_hash = @token_hash AND c.retain_until > now()
LIMIT 1;

-- name: FindReusedRefreshToken :one
-- Reuse lookup with the retention cutoff enforced (TRD 8.4 step 3), returning the session and
-- its owner for the revocation and the audit event.
SELECT c.session_id, s.user_id
FROM refresh_tokens_consumed c
JOIN sessions s ON s.id = c.session_id
WHERE c.token_hash = @token_hash AND c.retain_until > now();
