-- Cross-cutting queries. TRD 01 section 6.10.

-- name: TryCleanupAdvisoryLock :one
-- Session-level advisory lock so only one instance runs a cleanup job. The caller must
-- hold one connection for the job and release with ReleaseCleanupAdvisoryLock.
SELECT pg_try_advisory_lock(@lock_key::bigint) AS acquired;

-- name: ReleaseCleanupAdvisoryLock :one
SELECT pg_advisory_unlock(@lock_key::bigint) AS released;
