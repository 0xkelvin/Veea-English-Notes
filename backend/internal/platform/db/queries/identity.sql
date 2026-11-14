-- Queries for the identity module (users). TRD 01 sections 3, 7.3, 7.4 and 7.5.
-- Business rules (eligibility, policy, hashing) live in the use cases, not here.

-- name: GetUserByEmailNormalized :one
-- Unlocked read for eligibility checks and password login (TRD 7.2 step 3, 7.4 step 1).
SELECT * FROM users WHERE email_normalized = @email_normalized;

-- name: GetUserByID :one
-- Unlocked read, for example GET /v1/me.
SELECT * FROM users WHERE id = @id;

-- name: LockUserForNoKeyUpdate :one
-- Lock level L3 (TRD 7.1). The only explicit lock mode ever taken on users.
-- It conflicts with other writers of the row but not with foreign-key checks from
-- sessions, outbox or challenge inserts, and it never upgrades a weaker lock.
SELECT * FROM users WHERE id = @id FOR NO KEY UPDATE;

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
