-- +goose Up
-- TRD 05: vocabulary sync. Sync starts closed: learning_sync_control.open stays false until the
-- rebuilt Flutter client passes its acceptance checks (TRD 05 §15.2) and an operator opens it.
CREATE TABLE IF NOT EXISTS learning_sync_control (
 id smallint PRIMARY KEY CHECK (id = 1),
 open boolean NOT NULL DEFAULT false,
 changed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO learning_sync_control (id, open) VALUES (1, false) ON CONFLICT (id) DO NOTHING;

-- One row per owner. The user FK cascades because this is exactly one row; every multi-row
-- learning table below is RESTRICT, so a user delete can never run an unbounded cascade: the
-- TRD 04 purge drains them in bounded batches first, and the erase fails closed otherwise.
CREATE TABLE IF NOT EXISTS learning_sync_heads (
 user_id uuid PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
 epoch uuid NOT NULL,
 revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
 tombstone_horizon bigint NOT NULL DEFAULT 0 CHECK (tombstone_horizon >= 0 AND tombstone_horizon <= revision),
 live_words integer NOT NULL DEFAULT 0 CHECK (live_words BETWEEN 0 AND 50000),
 content_bytes bigint NOT NULL DEFAULT 0 CHECK (content_bytes BETWEEN 0 AND 67108864),
 created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO learning_sync_heads (user_id, epoch) SELECT id, gen_random_uuid() FROM users ON CONFLICT (user_id) DO NOTHING;

-- Every account gets its head in the transaction that creates it, whichever path inserts the user.
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION learning_create_sync_head() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO learning_sync_heads (user_id, epoch) VALUES (NEW.id, gen_random_uuid()) ON CONFLICT (user_id) DO NOTHING;
  RETURN NULL;
END
$$;
-- +goose StatementEnd
DROP TRIGGER IF EXISTS users_learning_sync_head ON users;
CREATE TRIGGER users_learning_sync_head AFTER INSERT ON users FOR EACH ROW EXECUTE FUNCTION learning_create_sync_head();

-- Server-issued writer identities (TRD 05 §5.2). Retirement is logical (retired_at); the row is
-- removed only after its mutation history has been deleted in bounded batches.
CREATE TABLE IF NOT EXISTS learning_sync_writers (
 user_id uuid NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
 writer_id uuid NOT NULL,
 epoch uuid NOT NULL,
 last_seq bigint NOT NULL DEFAULT 0 CHECK (last_seq >= 0),
 created_at timestamptz NOT NULL DEFAULT now(),
 last_used_at timestamptz NOT NULL DEFAULT now(),
 retired_at timestamptz,
 PRIMARY KEY (user_id, writer_id)
);
CREATE INDEX IF NOT EXISTS learning_sync_writers_lru ON learning_sync_writers (user_id, last_used_at, created_at, writer_id) WHERE retired_at IS NULL;
CREATE INDEX IF NOT EXISTS learning_sync_writers_retired ON learning_sync_writers (retired_at) WHERE retired_at IS NOT NULL;

-- 30-day deduplication records. result holds fixed codes, field names and revisions only.
CREATE TABLE IF NOT EXISTS learning_mutations (
 user_id uuid NOT NULL,
 writer_id uuid NOT NULL,
 seq bigint NOT NULL CHECK (seq > 0),
 request_hash bytea NOT NULL,
 result jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (user_id, writer_id, seq),
 FOREIGN KEY (user_id, writer_id) REFERENCES learning_sync_writers (user_id, writer_id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS learning_mutations_expiry ON learning_mutations (created_at);

-- Vocabulary items, keyed and tombstoned per owner. A tombstone keeps no content or dates.
CREATE TABLE IF NOT EXISTS vocabulary_items (
 user_id uuid NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
 id uuid NOT NULL,
 word text,
 meaning text,
 pronunciation text,
 part_of_speech text CHECK (part_of_speech IN ('n', 'v', 'adj', 'adv', 'phr', 'idm', 'etc')),
 source text,
 examples text[],
 tags text[],
 capture_day date,
 client_created_at timestamptz,
 content_bytes integer NOT NULL,
 revision bigint NOT NULL CHECK (revision > 0),
 created_revision bigint NOT NULL CHECK (created_revision > 0),
 field_revisions jsonb NOT NULL,
 deleted_at timestamptz,
 deleted_revision bigint,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (user_id, id),
 CONSTRAINT vocabulary_items_live_or_tombstone CHECK (
  (deleted_at IS NULL AND deleted_revision IS NULL AND word IS NOT NULL AND meaning IS NOT NULL
   AND examples IS NOT NULL AND tags IS NOT NULL AND capture_day IS NOT NULL AND client_created_at IS NOT NULL
   AND content_bytes BETWEEN 1 AND 8192)
  OR
  (deleted_at IS NOT NULL AND deleted_revision IS NOT NULL AND word IS NULL AND meaning IS NULL
   AND pronunciation IS NULL AND part_of_speech IS NULL AND source IS NULL AND examples IS NULL AND tags IS NULL
   AND capture_day IS NULL AND client_created_at IS NULL AND content_bytes = 0 AND field_revisions = '{}'::jsonb))
);
CREATE INDEX IF NOT EXISTS vocabulary_items_feed ON vocabulary_items (user_id, revision);
CREATE INDEX IF NOT EXISTS vocabulary_items_tombstones ON vocabulary_items (deleted_at) WHERE deleted_at IS NOT NULL;

-- TRD 04 export, schema version 2: sealed 1 MiB chunks (TRD 05 §11.1). At most 76 per export.
CREATE TABLE IF NOT EXISTS account_export_chunks (
 operation_id uuid NOT NULL REFERENCES account_operations (id) ON DELETE RESTRICT,
 seq integer NOT NULL CHECK (seq BETWEEN 0 AND 75),
 final boolean NOT NULL,
 key_id smallint NOT NULL,
 sealed bytea NOT NULL CHECK (octet_length(sealed) <= 1048605),
 PRIMARY KEY (operation_id, seq)
);
ALTER TABLE account_operations ADD COLUMN IF NOT EXISTS schema_version smallint;
ALTER TABLE account_operations ADD COLUMN IF NOT EXISTS artifact_plain_bytes bigint;
-- Version-1 artifacts are not served by the version-2 download path; end any that are ready.
-- The owner can request a new export once the TRD 04 daily window allows it.
UPDATE account_operations SET state = 'expired', artifact_ciphertext = NULL, artifact_key_id = NULL
 WHERE action = 'export' AND state = 'ready' AND schema_version IS NULL;
