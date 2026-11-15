-- Same isolated connection as prepare-isolated.sql, AFTER the real purge has drained.
-- A second invocation rotates again (safe); it never opens sync.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
DO $$ BEGIN
 IF current_setting('veea.restore_isolated',true) IS DISTINCT FROM 'yes'
    OR to_regclass('pg_temp.restore_heads_before') IS NULL THEN
   RAISE EXCEPTION 'isolated restore session required';
 END IF;
 IF EXISTS(SELECT 1 FROM learning_sync_control WHERE open)
 OR EXISTS(SELECT 1 FROM users u JOIN deletion_ledger d ON d.user_id=u.id)
 OR EXISTS(SELECT 1 FROM account_operations WHERE action='delete' AND state='pending')
 OR EXISTS(SELECT 1 FROM vocabulary_items v JOIN deletion_ledger d USING(user_id))
 OR EXISTS(SELECT 1 FROM learning_sync_writers v JOIN deletion_ledger d USING(user_id))
 OR EXISTS(SELECT 1 FROM learning_sync_heads v JOIN deletion_ledger d USING(user_id))
 OR EXISTS(SELECT 1 FROM cartridge_installations v JOIN deletion_ledger d USING(user_id))
 OR EXISTS(SELECT 1 FROM entitlement_grants v JOIN deletion_ledger d USING(user_id)) THEN
   RAISE EXCEPTION 'deletions have not drained; traffic and sync must remain closed';
 END IF;
END $$;
UPDATE learning_sync_heads SET epoch=gen_random_uuid();
UPDATE learning_sync_writers SET retired_at=COALESCE(retired_at,clock_timestamp());
COMMIT;
