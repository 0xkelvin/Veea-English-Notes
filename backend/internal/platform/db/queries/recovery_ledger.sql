-- Operator-only independent checkpoints. Read all retained rows while writes/cleanup are fenced.
-- name: LockRecoveryLedger :exec
LOCK TABLE deletion_ledger IN SHARE MODE;

-- name: ListRecoveryLedger :many
SELECT operation_id, user_id, accepted_at, completed_at, retain_until
FROM deletion_ledger
WHERE completed_at IS NULL OR retain_until IS NULL OR retain_until > sqlc.arg(covered_through)::timestamptz
ORDER BY user_id LIMIT 1000001;
