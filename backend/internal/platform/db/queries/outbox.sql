-- Queries for the email outbox. TRD 01 sections 6.7, 8.2 and 8.3.
--
-- Worker rule: every result write carries the lease guard G, a matching and unexpired
-- lease on a still-pending row. Zero rows affected means the worker lost its claim and must
-- discard its result. All timestamps here use the database clock.

-- name: InsertOutboxEmail :one
-- Lock level L5. Written in the same transaction as the state change that triggers it.
-- not_after: OTP mail passes the challenge's expires_at. Notifications pass NULL and get
-- created_at + 24 h on the database clock (TRD 6.7).
INSERT INTO email_outbox (
    id, user_id, challenge_id, to_email, template, payload_ciphertext, payload_key_id, not_after
) VALUES (
    @id, @user_id, @challenge_id, @to_email, @template, @payload_ciphertext, @payload_key_id,
    COALESCE(sqlc.narg(not_after)::timestamptz, now() + make_interval(hours => 24))
)
RETURNING *;

-- name: GetOutboxChallengeState :one
-- Pre-send re-check (TRD 8.2, 8.3 step 3), read without locks. is_open is false when the
-- challenge was consumed or superseded, has expired on the database clock, or is not a code
-- challenge. No row means the challenge is gone, which the worker treats as closed.
SELECT (consumed_at IS NULL
        AND superseded_at IS NULL
        AND expires_at > now()
        AND delivery = 'code')::boolean AS is_open
FROM otp_challenges
WHERE id = @id;

-- name: CancelPendingOutboxForChallenge :execrows
-- Lock level L5, always after the user and session locks (TRD 7.3, 7.5). Also clears the
-- lease, so a worker that is mid-send finds its result write rejected.
UPDATE email_outbox
SET status = 'cancelled', payload_ciphertext = NULL, finished_at = now(),
    lease_token = NULL, lease_expires_at = NULL
WHERE challenge_id = @challenge_id AND status = 'pending';

-- name: ReapOutbox :execrows
-- Worker step 1 (TRD 8.3). Terminalizes rows that can no longer be sent and that no live
-- lease protects. This also recovers rows left behind by a crash after the fifth reservation.
-- The cleanup job runs the same statement as a backstop.
UPDATE email_outbox
SET status = CASE WHEN now() >= not_after THEN 'expired' ELSE 'failed' END,
    last_error = CASE WHEN now() >= not_after THEN 'not_after_passed' ELSE 'send_budget_exhausted' END,
    payload_ciphertext = NULL, finished_at = now(), lease_token = NULL, lease_expires_at = NULL
WHERE status = 'pending'
  AND (now() >= not_after OR send_attempts >= 5)
  AND (lease_expires_at IS NULL OR lease_expires_at <= now());

-- name: ClaimOutboxBatch :many
-- Worker step 2 (TRD 8.3). Takes a lease and consumes no send budget.
UPDATE email_outbox o
SET lease_token = gen_random_uuid(),
    lease_expires_at = now() + make_interval(secs => @lease_seconds::double precision)
WHERE o.id IN (
    SELECT c.id FROM email_outbox c
    WHERE c.status = 'pending'
      AND c.send_attempts < 5
      AND c.next_attempt_at <= now()
      AND now() < c.not_after
      AND (c.lease_expires_at IS NULL OR c.lease_expires_at <= now())
    ORDER BY c.next_attempt_at
    LIMIT @batch_size
    FOR UPDATE SKIP LOCKED
)
RETURNING *;

-- name: ReleaseOutboxLease :execrows
-- Skipped claim (TRD 8.3 step 3): give the row back without consuming budget.
UPDATE email_outbox
SET lease_token = NULL, lease_expires_at = NULL
WHERE id = @id AND status = 'pending' AND lease_token = @lease_token AND lease_expires_at > now();

-- name: ReserveOutboxSend :one
-- Worker step 4 (TRD 8.3). Durably reserves one provider send under a live lease that still
-- has at least min_remaining_seconds left. No row means do not call the provider.
UPDATE email_outbox
SET send_attempts = send_attempts + 1, last_send_started_at = now()
WHERE id = @id
  AND status = 'pending'
  AND lease_token = @lease_token
  AND lease_expires_at > now() + make_interval(secs => @min_remaining_seconds::double precision)
  AND send_attempts < 5
  AND now() < not_after
RETURNING send_attempts;

-- name: FinishOutboxUnderLease :execrows
-- Worker step 6 (TRD 8.3), terminal results: sent, failed, cancelled. Guard G applies.
UPDATE email_outbox
SET status = @status, payload_ciphertext = NULL, finished_at = now(),
    provider_message_id = @provider_message_id, last_error = @last_error,
    lease_token = NULL, lease_expires_at = NULL
WHERE id = @id AND status = 'pending' AND lease_token = @lease_token AND lease_expires_at > now();

-- name: RescheduleOutboxUnderLease :execrows
-- Worker step 6, retryable result with budget left. Stays pending with backoff. Guard G applies.
UPDATE email_outbox
SET next_attempt_at = now() + make_interval(secs => @backoff_seconds::double precision),
    last_error = @last_error, lease_token = NULL, lease_expires_at = NULL
WHERE id = @id AND status = 'pending' AND lease_token = @lease_token AND lease_expires_at > now();

-- name: DeleteFinishedOutbox :execrows
-- Cleanup job (TRD 6.10): terminal rows, 7 days after finished_at, one batch, picked through
-- email_outbox_finished and deleted by tuple id (see DeleteOldRateLimitCounters), with the
-- predicate repeated on the outer side.
DELETE FROM email_outbox
WHERE ctid = ANY (ARRAY(
    SELECT ctid FROM email_outbox
    WHERE status <> 'pending' AND finished_at < now() - interval '7 days'
    LIMIT @batch_size
))
  AND status <> 'pending' AND finished_at < now() - interval '7 days';

-- name: CountPendingOutbox :one
-- email_outbox_pending (TRD 11.3), read when metrics are scraped. Uses the partial index.
SELECT count(*) FROM email_outbox WHERE status = 'pending';
