-- TRD 04. Only identity/accounts writes users; OTP owns challenge deletion.
-- name: SetAccountState :exec
UPDATE users SET status= @status, lifecycle_revision=lifecycle_revision+1,
 state_changed_at=clock_timestamp(), updated_at=clock_timestamp(),
 password_hash=CASE WHEN @status::text='pending_deletion' THEN NULL ELSE password_hash END,
 display_name=CASE WHEN @status::text='pending_deletion' THEN NULL ELSE display_name END,
 preferred_language=CASE WHEN @status::text='pending_deletion' THEN 'en' ELSE preferred_language END,
 time_zone=CASE WHEN @status::text='pending_deletion' THEN 'UTC' ELSE time_zone END,
 daily_goal=CASE WHEN @status::text='pending_deletion' THEN 20 ELSE daily_goal END,
 -- TRD 06: leaving 'suspended' (owner deletion while suspended) clears the saved suspension.
 resume_status=NULL, suspension_reason=NULL, suspension_ticket_ref=NULL, suspended_by=NULL
WHERE id= @id;

-- name: InsertAccountOperation :exec
INSERT INTO account_operations(id,token_hash,action,user_id,challenge_id,email_revision,lifecycle_revision,proof_expires_at,expires_at,artifact_id)
VALUES(@id,@token_hash,@action,@user_id,@challenge_id,@email_revision,@lifecycle_revision,@proof_expires_at,@proof_expires_at,@artifact_id);
-- name: GetAccountOperation :one
SELECT * FROM account_operations WHERE id= @id AND action= @action AND token_hash= @token_hash AND expires_at>clock_timestamp();
-- name: LockAccountOperation :one
SELECT * FROM account_operations WHERE id= @id FOR UPDATE;
-- name: AcceptAccountOperation :exec
UPDATE account_operations SET state= @state, accepted_at=clock_timestamp(),
 completed_at=CASE WHEN @state::text='completed' THEN clock_timestamp() ELSE NULL END,
 expires_at=clock_timestamp()+CASE WHEN action='delete' THEN interval '30 days' ELSE interval '7 days' END,
 email_digests= @email_digests
WHERE id= @id;
-- name: HasRecentExport :one
SELECT EXISTS(SELECT 1 FROM account_operations WHERE user_id= @user_id AND action='export' AND accepted_at>clock_timestamp()-interval '24 hours') AS recent;
-- name: CancelAccountExports :many
UPDATE account_operations SET state='canceled',artifact_ciphertext=NULL,artifact_key_id=NULL,completed_at=clock_timestamp()
WHERE user_id= @user_id AND action='export' AND state IN ('pending','ready')
RETURNING id;
-- name: PublishAccountExport :execrows
-- Schema version 3 (TRD 09 adds entitlements): the sealed chunks are already inserted in the same transaction (TRD 05 §11.1).
UPDATE account_operations SET state='ready',schema_version=3,artifact_plain_bytes= @artifact_plain_bytes,
 artifact_key_id= @artifact_key_id,download_expires_at=clock_timestamp()+interval '24 hours',completed_at=clock_timestamp()
WHERE id= @id AND state='pending';
-- name: ListAccountJobs :many
SELECT id FROM account_operations WHERE state='pending' ORDER BY created_at,id LIMIT @batch_size;
-- name: AdvanceAccountPurge :exec
UPDATE account_operations SET purge_step= @purge_step WHERE id= @id;
-- name: CompleteAccountPurge :exec
UPDATE account_operations SET state='completed',completed_at=clock_timestamp(),email_digests='{}',challenge_id='00000000-0000-0000-0000-000000000000' WHERE id= @id;
-- name: InsertDeletionLedger :exec
INSERT INTO deletion_ledger(operation_id,user_id,accepted_at) VALUES(@operation_id,@user_id,clock_timestamp());
-- name: CompleteDeletionLedger :exec
UPDATE deletion_ledger SET completed_at=clock_timestamp(),retain_until=clock_timestamp()+interval '90 days' WHERE operation_id= @operation_id;
-- name: FenceDeletedAddress :exec
INSERT INTO erased_addresses(email_hmac,cutoff) VALUES(@email_hmac,clock_timestamp())
ON CONFLICT(email_hmac) DO UPDATE SET cutoff=EXCLUDED.cutoff,expires_at=NULL;
-- name: ExpireDeletedAddressFence :exec
UPDATE erased_addresses SET expires_at=clock_timestamp()+interval '24 hours' WHERE email_hmac=ANY(@email_digests::bytea[]);
-- name: LatestDeletionCutoff :one
SELECT COALESCE(max(cutoff),to_timestamp(0))::timestamptz AS cutoff FROM erased_addresses WHERE email_hmac=ANY(@email_digests::bytea[]) AND (expires_at IS NULL OR expires_at>clock_timestamp());
-- name: MinimizeAccountAudit :execrows
UPDATE audit_events SET email_hmac=NULL,ip=NULL,user_agent=NULL,request_id=NULL,metadata='{}'
WHERE id IN (SELECT e.id FROM audit_events e WHERE (e.actor_user_id= @user_id OR e.target_user_id= @user_id) AND (e.email_hmac IS NOT NULL OR e.ip IS NOT NULL OR e.user_agent IS NOT NULL OR e.request_id IS NOT NULL OR e.metadata<>'{}') ORDER BY e.id LIMIT @batch_size);
-- name: PurgeAccountOutbox :execrows
DELETE FROM email_outbox WHERE id IN (SELECT o.id FROM email_outbox o WHERE o.user_id= @user_id ORDER BY o.id LIMIT @batch_size);
-- name: DeleteAccount :execrows
DELETE FROM users WHERE id= @id AND status='pending_deletion';
-- name: HasAccountChallenges :one
SELECT EXISTS(SELECT 1 FROM otp_challenges WHERE user_id= @user_id) AS remaining;
-- name: DeleteAccountEmailChanges :exec
DELETE FROM email_changes WHERE user_id= @user_id;
-- name: DeleteAccountSessions :execrows
DELETE FROM sessions WHERE id IN (SELECT s.id FROM sessions s WHERE s.user_id= @user_id ORDER BY s.id LIMIT @batch_size);
-- name: ExpireAccountArtifacts :many
UPDATE account_operations SET artifact_ciphertext=NULL,artifact_key_id=NULL,state='expired'
WHERE id IN (SELECT o.id FROM account_operations o WHERE o.state='ready' AND o.download_expires_at<=clock_timestamp()
 ORDER BY o.id LIMIT @batch_size FOR UPDATE SKIP LOCKED)
RETURNING id,user_id;
-- name: CleanupAccountOperations :execrows
DELETE FROM account_operations WHERE id IN (SELECT id FROM account_operations WHERE expires_at<=clock_timestamp() AND state<>'pending' LIMIT @batch_size);
-- name: CleanupDeletionLedger :execrows
DELETE FROM deletion_ledger WHERE operation_id IN (SELECT operation_id FROM deletion_ledger WHERE retain_until<=clock_timestamp() LIMIT @batch_size);
-- name: CleanupAddressFences :execrows
DELETE FROM erased_addresses WHERE email_hmac IN (SELECT email_hmac FROM erased_addresses WHERE expires_at<=clock_timestamp() LIMIT @batch_size);
-- name: CleanupOldAudit :execrows
DELETE FROM audit_events WHERE id IN (SELECT id FROM audit_events WHERE occurred_at<clock_timestamp()-interval '180 days' ORDER BY occurred_at,id LIMIT @batch_size);

-- name: ReadAccountOperation :one
SELECT * FROM account_operations WHERE id= @id;
-- name: LockAccountOperations :many
SELECT id FROM account_operations WHERE user_id= @user_id ORDER BY id FOR UPDATE;
-- name: LockAccountEmailChanges :many
SELECT id FROM email_changes WHERE user_id= @user_id ORDER BY id FOR UPDATE;
-- name: DeleteOtherAccountOperations :exec
DELETE FROM account_operations WHERE user_id= @user_id AND id<> @keep_id;

-- name: ExpirePendingOperationCapabilities :execrows
UPDATE account_operations SET token_hash=NULL
WHERE id IN (SELECT o.id FROM account_operations o WHERE o.expires_at<=clock_timestamp() AND o.state='pending' AND o.token_hash IS NOT NULL
 ORDER BY o.id LIMIT @batch_size);

-- name: CancelAccountOperation :execrows
UPDATE account_operations SET state='canceled',artifact_ciphertext=NULL,artifact_key_id=NULL,completed_at=clock_timestamp()
WHERE id= @id AND action='export' AND state IN ('pending','ready');

-- name: OldestPendingDeletionSeconds :one
-- Age of the oldest accepted deletion whose purge has not completed (TRD 04 §6.2 24 h target).
SELECT COALESCE(EXTRACT(EPOCH FROM clock_timestamp()-min(accepted_at)),0)::float8 AS age
FROM account_operations WHERE action='delete' AND state='pending';
