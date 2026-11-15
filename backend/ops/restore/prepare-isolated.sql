-- OPERATOR ONLY: no API/worker/traffic attached. Run after migration 00015.
-- Same connection must load the private SQL from admin ledger recover, including
-- restore_deletions + restore_recovery_proof, and SET veea.restore_isolated='yes'.
-- This is not a migration or an API action. Keep the gate closed on every outcome.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
DO $$ BEGIN
 IF current_setting('veea.restore_isolated', true) IS DISTINCT FROM 'yes'
    OR to_regclass('pg_temp.restore_deletions') IS NULL
    OR to_regclass('pg_temp.restore_recovery_proof') IS NULL THEN
   RAISE EXCEPTION 'isolated restore acknowledgement and authoritative ledger required';
 END IF;
 IF (SELECT count(*) FROM restore_recovery_proof) <> 1
 OR EXISTS(SELECT 1 FROM restore_recovery_proof WHERE source_id='00000000-0000-0000-0000-000000000000'
     OR generation < min_generation OR min_generation < 1 OR covered_through < required_through
     OR backup_at < backup_floor OR backup_at > required_through
     OR backup_floor <> covered_through - interval '720 hours'
     OR record_count <> (SELECT count(*) FROM restore_deletions)
     OR checkpoint_digest !~ '^[a-f0-9]{64}$') THEN
   RAISE EXCEPTION 'independent recovery proof missing, incomplete or behind; keep access closed';
 END IF;
 IF EXISTS (SELECT 1 FROM learning_sync_control WHERE open) THEN
   RAISE EXCEPTION 'close sync before preparing an isolated restore';
 END IF;
 IF (SELECT max(version_id) FROM goose_db_version WHERE is_applied) IS DISTINCT FROM 15 THEN
   RAISE EXCEPTION 'restore requires schema 15';
 END IF;
 IF EXISTS (SELECT 1 FROM restore_deletions i JOIN deletion_ledger d USING (user_id)
            WHERE i.operation_id <> d.operation_id)
 OR EXISTS (SELECT 1 FROM restore_deletions i JOIN account_operations o ON o.id=i.operation_id
            WHERE o.action<>'delete' OR o.user_id IS DISTINCT FROM i.user_id) THEN
   RAISE EXCEPTION 'ledger identity conflict requires operator investigation';
 END IF;
END $$;
UPDATE learning_sync_control SET open=false, changed_at=clock_timestamp();
CREATE TEMP TABLE IF NOT EXISTS restore_heads_before ON COMMIT PRESERVE ROWS AS
 SELECT user_id, epoch FROM learning_sync_heads;
INSERT INTO deletion_ledger(operation_id,user_id,accepted_at,completed_at,retain_until)
 SELECT operation_id,user_id,accepted_at,completed_at,retain_until FROM restore_deletions
 ON CONFLICT(operation_id) DO UPDATE SET
   completed_at=EXCLUDED.completed_at, retain_until=EXCLUDED.retain_until;
-- Include ledger rows already in the backup, not merely the post-backup delta.
-- There is no traffic: the regular purge runs before address reuse becomes possible.
UPDATE users u SET status='pending_deletion', lifecycle_revision=lifecycle_revision+1,
 state_changed_at=clock_timestamp(), updated_at=clock_timestamp(), password_hash=NULL,
 display_name=NULL, preferred_language='en',time_zone='UTC',daily_goal=20,
 resume_status=NULL,suspension_reason=NULL,suspension_ticket_ref=NULL,suspended_by=NULL
 WHERE EXISTS (SELECT 1 FROM deletion_ledger d WHERE d.user_id=u.id);
UPDATE deletion_ledger d SET completed_at=NULL,retain_until=NULL
 WHERE EXISTS (SELECT 1 FROM users u WHERE u.id=d.user_id);
INSERT INTO account_operations(id,token_hash,action,user_id,challenge_id,email_revision,
 lifecycle_revision,state,created_at,proof_expires_at,accepted_at,expires_at,artifact_id,purge_step)
 SELECT d.operation_id,NULL,'delete',u.id,'00000000-0000-0000-0000-000000000000',
 u.email_revision,u.lifecycle_revision,'pending',d.accepted_at,clock_timestamp(),d.accepted_at,
 clock_timestamp()+interval '30 days',gen_random_uuid(),0
 FROM deletion_ledger d JOIN users u ON u.id=d.user_id
 ON CONFLICT(id) DO UPDATE SET state='pending',purge_step=0,token_hash=NULL,
 completed_at=NULL,email_revision=EXCLUDED.email_revision,lifecycle_revision=EXCLUDED.lifecycle_revision;
-- No restored credential, proof or export may authorize a new action.
UPDATE sessions SET revoked_at=COALESCE(revoked_at,clock_timestamp()),
 revoked_reason=COALESCE(revoked_reason,'account_inactive');
UPDATE otp_challenges SET superseded_at=COALESCE(superseded_at,clock_timestamp()),pending_password_hash=NULL;
UPDATE account_operations SET token_hash=NULL;
DELETE FROM account_export_chunks;
UPDATE account_operations SET artifact_ciphertext=NULL,artifact_key_id=NULL,
 download_expires_at=NULL,artifact_plain_bytes=NULL,
 state=CASE WHEN action='export' OR accepted_at IS NULL THEN 'canceled' ELSE state END;
UPDATE email_outbox SET status='cancelled',payload_ciphertext=NULL,payload_key_id=NULL,
 lease_token=NULL,lease_expires_at=NULL,finished_at=clock_timestamp()
 WHERE status='pending';
COMMIT;
-- Start only an isolated current-version cleanup process; then run finish-isolated.sql
-- in THIS session after it has drained. Do not start public ingress or an email sender.
