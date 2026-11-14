-- Queries for the append-only audit trail. TRD 01 sections 6.8 and 11.1.
-- The application role may only INSERT and SELECT. Callers must never put a password,
-- code, token, token hash or ciphertext in reason or metadata.

-- name: InsertAuditEvent :exec
INSERT INTO audit_events (
    action, outcome, reason, actor_user_id, target_user_id, session_id,
    email_hmac, ip, user_agent, request_id, metadata
) VALUES (
    @action, @outcome, @reason, @actor_user_id, @target_user_id, @session_id,
    @email_hmac, @ip, @user_agent, @request_id, @metadata
);

-- name: ListAuditEventsForTarget :many
-- Read side for tests and the later admin tooling (Phase 5). Newest first.
SELECT * FROM audit_events
WHERE target_user_id = @target_user_id
ORDER BY occurred_at DESC, id DESC
LIMIT @row_limit;
