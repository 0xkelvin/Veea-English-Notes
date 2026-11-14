-- Queries for fixed-window rate limits. TRD 01 sections 6.9 and 10.
-- Each call is a single autocommit statement outside the main transaction (TRD 7.1 rule 6).

-- name: IncrementRateLimitCounter :one
-- Returns the count after the increment. The caller compares it with the limit.
INSERT INTO rate_limit_counters (key, window_start, count)
VALUES (@key, @window_start, 1)
ON CONFLICT (key, window_start) DO UPDATE SET count = rate_limit_counters.count + 1
RETURNING count;

-- name: GetRateLimitCount :one
-- Read-only pre-check without incrementing. Returns 0 for an unused key.
SELECT COALESCE(sum(count), 0)::bigint AS total
FROM rate_limit_counters
WHERE key = @key AND window_start >= @since;

-- name: DeleteOldRateLimitCounters :execrows
-- Cleanup job (TRD 6.10): windows older than 48 hours.
DELETE FROM rate_limit_counters
WHERE (key, window_start) IN (
    SELECT key, window_start FROM rate_limit_counters
    WHERE window_start < now() - interval '48 hours'
    LIMIT @batch_size
);

-- name: IncrementRateLimitWindow :one
-- Fixed-window increment on database time (TRD 10). The window is the epoch-aligned bucket of
-- window_seconds that contains now() (date_bin, PostgreSQL 14 or newer), so every instance
-- agrees on boundaries whatever its own clock says. One atomic upsert: concurrent callers each
-- get a distinct count. Returns the window start and the database now(), from which the caller
-- derives Retry-After. Run it on the pool in autocommit mode, because now() is the transaction
-- start and would be stale inside a long transaction. The ratelimit package enforces that by
-- taking a *pgxpool.Pool.
INSERT INTO rate_limit_counters (key, window_start, count)
VALUES (@key, date_bin(make_interval(secs => @window_seconds::bigint), now(), to_timestamp(0)), 1)
ON CONFLICT (key, window_start) DO UPDATE SET count = rate_limit_counters.count + 1
RETURNING count, window_start, now()::timestamptz AS db_now;

-- name: PeekRateLimitWindow :one
-- Read-only counterpart of IncrementRateLimitWindow for pre-checks (TRD 7.3 step P). Returns the
-- window start, the database now(), and the current count (0 when the window has no row yet).
SELECT
    date_bin(make_interval(secs => @window_seconds::bigint), now(), to_timestamp(0))::timestamptz AS window_start,
    now()::timestamptz AS db_now,
    COALESCE((
        SELECT c.count FROM rate_limit_counters c
        WHERE c.key = @key AND c.window_start = date_bin(make_interval(secs => @window_seconds::bigint), now(), to_timestamp(0))
    ), 0)::int AS count;
