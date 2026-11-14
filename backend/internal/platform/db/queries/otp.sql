-- Queries for OTP challenges and cooldowns. TRD 01 sections 4, 6.3, 6.4, 7.2 and 7.3.

-- name: ClaimOTPCooldown :one
-- Lock level L1, TRD 7.2 step 1. Atomic per (purpose, email) cooldown claim.
-- Returns a row when this caller may issue a challenge and no row (pgx.ErrNoRows)
-- while the cooldown is active. A concurrent first claim blocks on the primary key
-- until the other transaction ends, then fails the WHERE against the committed row.
INSERT INTO otp_cooldowns (purpose, email_hmac, last_issued_at)
VALUES (@purpose, @email_hmac, now())
ON CONFLICT (purpose, email_hmac) DO UPDATE
    SET last_issued_at = EXCLUDED.last_issued_at
    WHERE otp_cooldowns.last_issued_at <= EXCLUDED.last_issued_at - make_interval(secs => @cooldown_seconds::double precision)
RETURNING last_issued_at;

-- name: SupersedeOpenOTPChallenges :many
-- Lock level L2, TRD 7.2 step 4. Supersedes the open challenge for the purpose and email
-- and drops any pending password hash. The returned ids are the old challenges whose
-- outbox rows the caller cancels at L5.
UPDATE otp_challenges
SET superseded_at = now(), pending_password_hash = NULL
WHERE purpose = @purpose
  AND change_id IS NULL
  AND email_normalized = @email_normalized
  AND consumed_at IS NULL
  AND superseded_at IS NULL
RETURNING id;

-- name: InsertOTPChallenge :one
INSERT INTO otp_challenges (
    id, token_hash, purpose, signup_method, pending_password_hash, email, email_normalized,
    user_id, session_id, code_hash, delivery, max_attempts, expires_at, request_ip, email_revision
) VALUES (
    @id, @token_hash, @purpose, @signup_method, @pending_password_hash, @email, @email_normalized,
    @user_id, @session_id, @code_hash, @delivery, @max_attempts, @expires_at, @request_ip, @email_revision
)
RETURNING *;

-- name: InsertEmailChangeChallenge :exec
INSERT INTO otp_challenges(id,token_hash,purpose,email,email_normalized,user_id,session_id,code_hash,delivery,max_attempts,expires_at,request_ip,email_revision,change_id)
VALUES (@id,@token_hash,@purpose,@email,@email_normalized,@user_id,@session_id,@code_hash,@delivery,@max_attempts,@expires_at,@request_ip,@email_revision,@change_id);

-- name: LockOTPProofPair :many
SELECT * FROM otp_challenges WHERE token_hash = ANY(@token_hashes::bytea[]) ORDER BY id FOR UPDATE;

-- name: LockOTPChallengeByTokenHash :one
-- Lock level L2, procedure V step 1 (TRD 7.3). Returns no row for an unknown token.
SELECT * FROM otp_challenges WHERE token_hash = @token_hash FOR UPDATE;

-- name: GetOTPChallengeEmailByTokenHash :one
-- Verify pre-check P (TRD 7.3): an unlocked autocommit read, before any transaction, of the
-- email whose verify-failure limit applies. No row means an unknown token.
SELECT email_normalized FROM otp_challenges WHERE token_hash = @token_hash;

-- name: IncrementOTPChallengeAttempts :execrows
-- Procedure V step 4. The caller commits this before returning an error.
UPDATE otp_challenges SET attempts = attempts + 1 WHERE id = @id;

-- name: ConsumeOTPChallenge :execrows
-- Procedure V step 5. The otp_none_inert constraint rejects this for delivery = 'none'.
UPDATE otp_challenges
SET consumed_at = now(), pending_password_hash = NULL
WHERE id = @id AND consumed_at IS NULL AND superseded_at IS NULL;

-- name: ClearExpiredPendingPasswordHashes :execrows
-- Cleanup job (TRD 6.10): no password hash outlives its challenge.
UPDATE otp_challenges
SET pending_password_hash = NULL
WHERE pending_password_hash IS NOT NULL AND expires_at <= now();

-- name: DeleteExpiredOTPChallenges :execrows
-- Cleanup job (TRD 6.10): 24 hours after expiry, oldest first, cascading to remaining outbox
-- rows. One batch picked through otp_challenges_expires and deleted by tuple id (see
-- DeleteOldRateLimitCounters), with the predicate repeated on the outer side.
DELETE FROM otp_challenges
WHERE ctid = ANY (ARRAY(
    SELECT ctid FROM otp_challenges
    WHERE expires_at < now() - interval '24 hours'
    ORDER BY expires_at
    LIMIT @batch_size
))
  AND expires_at < now() - interval '24 hours';

-- name: DeleteStaleOTPCooldowns :execrows
-- Cleanup job (TRD 6.10): last issued more than 24 hours ago, one batch, picked through
-- otp_cooldowns_last_issued and deleted by tuple id (see DeleteOldRateLimitCounters). A cooldown
-- re-claimed meanwhile fails the repeated predicate on its new version and is not deleted.
DELETE FROM otp_cooldowns
WHERE ctid = ANY (ARRAY(
    SELECT ctid FROM otp_cooldowns
    WHERE last_issued_at < now() - interval '24 hours'
    LIMIT @batch_size
))
  AND last_issued_at < now() - interval '24 hours';

-- name: GetOTPCooldownRemaining :one
-- Seconds left on an active cooldown (never negative), for Retry-After after ClaimOTPCooldown
-- found no row. Uses the same now() as the claim. No row means the cooldown row was cleaned up
-- in between, so the caller may simply retry.
SELECT GREATEST(
    0,
    extract(epoch FROM (last_issued_at + make_interval(secs => @cooldown_seconds::double precision) - now()))
)::double precision AS seconds_remaining
FROM otp_cooldowns
WHERE purpose = @purpose AND email_hmac = @email_hmac;
