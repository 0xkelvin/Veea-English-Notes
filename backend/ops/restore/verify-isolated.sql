-- Read-only, same session; fails closed if a restore invariant is unmet.
DO $$ BEGIN
 IF current_setting('veea.restore_isolated',true) IS DISTINCT FROM 'yes'
    OR to_regclass('pg_temp.restore_heads_before') IS NULL
    OR to_regclass('pg_temp.restore_recovery_proof') IS NULL
    OR to_regclass('pg_temp.restore_deletions') IS NULL THEN
   RAISE EXCEPTION 'isolated restore session required';
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
 IF EXISTS(SELECT 1 FROM learning_sync_control WHERE open)
 OR EXISTS(SELECT 1 FROM learning_sync_heads h JOIN restore_heads_before b USING(user_id) WHERE h.epoch=b.epoch)
 OR EXISTS(SELECT 1 FROM learning_sync_writers WHERE retired_at IS NULL)
 OR EXISTS(SELECT 1 FROM users u JOIN deletion_ledger d ON d.user_id=u.id)
 OR EXISTS(SELECT 1 FROM sessions WHERE revoked_at IS NULL)
 OR EXISTS(SELECT 1 FROM otp_challenges WHERE superseded_at IS NULL OR pending_password_hash IS NOT NULL)
 OR EXISTS(SELECT 1 FROM account_operations WHERE token_hash IS NOT NULL OR artifact_ciphertext IS NOT NULL OR state IN ('pending','ready'))
 OR EXISTS(SELECT 1 FROM account_export_chunks)
 OR EXISTS(SELECT 1 FROM email_outbox WHERE status='pending') THEN
   RAISE EXCEPTION 'restore verification failed; traffic and sync must remain closed';
 END IF;
END $$;
SELECT (SELECT max(version_id) FROM goose_db_version WHERE is_applied) AS schema_version,
       (SELECT open FROM learning_sync_control) AS sync_open,
       (SELECT count(*) FROM deletion_ledger) AS retained_deletion_markers,
       (SELECT count(*) FROM users u JOIN deletion_ledger d ON u.id=d.user_id) AS deleted_owners_remaining,
       (SELECT count(*) FROM learning_sync_heads) AS rotated_heads;
