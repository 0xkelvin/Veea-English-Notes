-- Queries for the identity module (users). TRD 01 sections 3, 7.3, 7.4 and 7.5.
-- Business rules (eligibility, policy, hashing) live in the use cases, not here.

-- name: GetUserByEmailNormalized :one
-- Unlocked read for eligibility checks and password login (TRD 7.2 step 3, 7.4 step 1).
SELECT * FROM users WHERE email_normalized = @email_normalized;

-- name: GetUserByID :one
-- Unlocked read, for example GET /v1/me.
SELECT * FROM users WHERE id = @id;

-- name: LockUserForNoKeyUpdate :one
-- Lock level L3 (TRD 7.1). All flows except TRD 03 final email cutover use this mode.
-- It conflicts with other writers of the row but not with foreign-key checks from
-- sessions, outbox or challenge inserts, and it never upgrades a weaker lock.
SELECT * FROM users WHERE id = @id FOR NO KEY UPDATE;

-- name: LockUserForEmailChange :one
-- TRD 03 L3 exception: changing a unique key needs the stronger mode from the outset.
SELECT * FROM users WHERE id = @id FOR UPDATE;

-- name: UpdateProfile :one
UPDATE users SET display_name = @display_name, preferred_language = @preferred_language,
    time_zone = @time_zone, daily_goal = @daily_goal, profile_revision = profile_revision + 1, updated_at = now()
WHERE id = @id RETURNING *;

-- name: ChangeVerifiedEmail :execrows
UPDATE users SET email = @email, email_normalized = @email_normalized, email_verified_at = now(),
    email_revision = email_revision + 1, updated_at = now()
WHERE id = @id;

-- name: LockPendingEmailChange :many
SELECT id FROM email_changes WHERE user_id = @user_id AND closed_at IS NULL ORDER BY id FOR UPDATE;

-- name: ClosePendingEmailChanges :exec
UPDATE email_changes SET closed_at = now() WHERE user_id = @user_id AND closed_at IS NULL;

-- name: InsertEmailChange :exec
INSERT INTO email_changes(id,user_id,session_id,source_email_normalized,source_revision,new_email,new_email_normalized,expires_at)
VALUES (@id,@user_id,@session_id,@source_email_normalized,@source_revision,@new_email,@new_email_normalized,@expires_at);

-- name: LockEmailChange :one
SELECT * FROM email_changes WHERE id = @id AND user_id = @user_id FOR UPDATE;

-- name: GetOwnedEmailChange :one
SELECT * FROM email_changes WHERE id = @id AND user_id = @user_id;

-- name: CloseEmailChange :exec
UPDATE email_changes SET closed_at = now() WHERE id = @id AND user_id = @user_id;

-- name: InsertUserIfAbsent :one
-- Signup verify (TRD 7.3). Returns no row when the email already has an account,
-- and never updates an existing row, so existing credentials cannot change.
INSERT INTO users (id, email, email_normalized, email_verified_at, password_hash, password_changed_at)
VALUES (@id, @email, @email_normalized, @email_verified_at, @password_hash, @password_changed_at)
ON CONFLICT (email_normalized) DO NOTHING
RETURNING *;

-- name: SetUserPassword :execrows
-- Set, change or reset: writes the hash and password_changed_at on a row the
-- transaction already holds under LockUserForNoKeyUpdate.
UPDATE users
SET password_hash = @password_hash, password_changed_at = now(), updated_at = now()
WHERE id = @id;

-- name: RehashUserPassword :execrows
-- Parameter upgrade after a successful login. Compare-and-set on the old hash so a
-- concurrent change or reset is never overwritten. Does not touch password_changed_at.
UPDATE users
SET password_hash = @new_hash, updated_at = now()
WHERE id = @id AND password_hash = @old_hash;

-- name: DeleteExpiredEmailChanges :execrows
-- TRD 03: after challenge cleanup, remove expired requests in bounded oldest-first batches.
-- NOT EXISTS avoids taking parent/FK locks before an in-flight L2 proof verifier.
DELETE FROM email_changes
WHERE ctid = ANY (ARRAY(
    SELECT e.ctid FROM email_changes e
    WHERE e.expires_at < now() - interval '24 hours'
      AND NOT EXISTS (SELECT 1 FROM otp_challenges c WHERE c.change_id = e.id)
    ORDER BY e.expires_at
    LIMIT @batch_size
)) AND expires_at < now() - interval '24 hours';

-- name: LockUserForKeyShare :one
-- Lock level L3 in its weakest mode (TRD 05 §14): learning writes only need the account to stay
-- active and present; it is compatible with every other L3 mode except the final erase.
SELECT * FROM users WHERE id = @id FOR KEY SHARE;
