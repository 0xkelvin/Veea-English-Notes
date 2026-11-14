-- +goose Up
-- TRD 01 section 6.10: indexes for the cleanup jobs in internal/maintenance and for the
-- foreign-key cascades their deletes trigger. Without these indexes the affected batches and cascade
-- lookups can scan whole tables. Only the challenge batch has ORDER BY (expires_at),
-- supported by its existing index. Other batches do not specify ordering.
--
-- Existing indexes already serve the other jobs: otp_challenges_expires (challenge delete and
-- its ORDER BY, pending-hash scrub), refresh_tokens_consumed_retain (consumed-token delete) and
-- email_outbox_due (outbox reaper, pending rows only).
--
-- Plain CREATE INDEX inside goose's transaction: the tables are empty or small when this first
-- runs, because the Go service has not shipped. CONCURRENTLY cannot run in a transaction, and a
-- failed concurrent build would leave an invalid index that IF NOT EXISTS then skips forever.

-- DeleteStaleSessions, revoked branch: revoked more than 30 days ago. Partial, so the many
-- active sessions are not in it.
CREATE INDEX IF NOT EXISTS sessions_revoked_at ON sessions (revoked_at) WHERE revoked_at IS NOT NULL;

-- DeleteStaleSessions, expiry branch: absolute expiry more than 30 days ago. The planner
-- combines it with sessions_revoked_at for the OR (BitmapOr).
CREATE INDEX IF NOT EXISTS sessions_absolute_expires ON sessions (absolute_expires_at);

-- Cascade from sessions (ON DELETE CASCADE looks consumed tokens up by session_id).
CREATE INDEX IF NOT EXISTS refresh_tokens_consumed_session ON refresh_tokens_consumed (session_id);

-- DeleteOldRateLimitCounters: windows older than 48 hours. window_start is the second
-- primary-key column, so the primary key cannot serve a range on it alone.
CREATE INDEX IF NOT EXISTS rate_limit_counters_window ON rate_limit_counters (window_start);

-- DeleteStaleOTPCooldowns: last issued more than 24 hours ago.
CREATE INDEX IF NOT EXISTS otp_cooldowns_last_issued ON otp_cooldowns (last_issued_at);

-- DeleteFinishedOutbox: terminal rows finished more than 7 days ago. Partial on the same
-- predicate as the query, so pending rows are not in it.
CREATE INDEX IF NOT EXISTS email_outbox_finished ON email_outbox (finished_at) WHERE status <> 'pending';

-- Cascade from otp_challenges (DeleteExpiredOTPChallenges) and CancelPendingOutboxForChallenge,
-- which run in every start and redemption transaction.
CREATE INDEX IF NOT EXISTS email_outbox_challenge ON email_outbox (challenge_id);
