-- TRD 05 learning data sync. Every owner-scoped write happens under the owner's head lock (L4c).

-- name: LearningSyncOpen :one
SELECT open FROM learning_sync_control WHERE id = 1;

-- name: GetLearningHead :one
SELECT * FROM learning_sync_heads WHERE user_id = @user_id;

-- name: EnsureLearningHead :exec
INSERT INTO learning_sync_heads (user_id, epoch) VALUES (@user_id, gen_random_uuid()) ON CONFLICT (user_id) DO NOTHING;

-- name: LockLearningHead :one
SELECT * FROM learning_sync_heads WHERE user_id = @user_id FOR UPDATE;

-- name: UpdateLearningHead :exec
UPDATE learning_sync_heads SET revision = @revision, live_words = @live_words, content_bytes = @content_bytes
WHERE user_id = @user_id;

-- name: GetLearningWriter :one
SELECT * FROM learning_sync_writers WHERE user_id = @user_id AND writer_id = @writer_id;

-- name: CountActiveLearningWriters :one
SELECT count(*) FROM learning_sync_writers WHERE user_id = @user_id AND retired_at IS NULL;

-- name: RetireLeastRecentLearningWriter :one
-- D9: oldest last_used_at, then oldest created_at, then the lowest writer_id (uuid order is bytewise).
UPDATE learning_sync_writers SET retired_at = now()
WHERE ctid = (
  SELECT w.ctid FROM learning_sync_writers w WHERE w.user_id = @user_id::uuid AND w.retired_at IS NULL
  ORDER BY w.last_used_at, w.created_at, w.writer_id LIMIT 1)
RETURNING writer_id;

-- name: InsertLearningWriter :one
INSERT INTO learning_sync_writers (user_id, writer_id, epoch) VALUES (@user_id, @writer_id, @epoch) RETURNING *;

-- name: AdvanceLearningWriter :exec
-- A push that returns 200 touches last_used_at; last_seq only moves forward.
UPDATE learning_sync_writers SET last_seq = GREATEST(last_seq, @last_seq), last_used_at = now()
WHERE user_id = @user_id AND writer_id = @writer_id;

-- name: ListLearningMutations :many
SELECT * FROM learning_mutations
WHERE user_id = @user_id AND writer_id = @writer_id AND seq BETWEEN @first_seq AND @last_seq ORDER BY seq;

-- name: InsertLearningMutation :exec
INSERT INTO learning_mutations (user_id, writer_id, seq, request_hash, result) VALUES (@user_id, @writer_id, @seq, @request_hash, @result);

-- name: GetVocabularyItem :one
SELECT * FROM vocabulary_items WHERE user_id = @user_id AND id = @id;

-- name: InsertVocabularyItem :exec
INSERT INTO vocabulary_items (user_id, id, word, meaning, pronunciation, part_of_speech, source, examples, tags,
  capture_day, client_created_at, content_bytes, revision, created_revision, field_revisions)
VALUES (@user_id, @id, @word, @meaning, @pronunciation, @part_of_speech, @source, @examples, @tags,
  @capture_day, @client_created_at, @content_bytes, @revision, @revision, @field_revisions);

-- name: UpdateVocabularyItem :exec
-- Writes a live item (an update, or a restore of a tombstone).
UPDATE vocabulary_items SET word = @word, meaning = @meaning, pronunciation = @pronunciation,
  part_of_speech = @part_of_speech, source = @source, examples = @examples, tags = @tags,
  capture_day = @capture_day, client_created_at = @client_created_at, content_bytes = @content_bytes,
  revision = @revision, field_revisions = @field_revisions, deleted_at = NULL, deleted_revision = NULL, updated_at = now()
WHERE user_id = @user_id AND id = @id;

-- name: TombstoneVocabularyItem :exec
UPDATE vocabulary_items SET word = NULL, meaning = NULL, pronunciation = NULL, part_of_speech = NULL, source = NULL,
  examples = NULL, tags = NULL, capture_day = NULL, client_created_at = NULL, content_bytes = 0,
  field_revisions = '{}'::jsonb, revision = @revision, deleted_revision = @revision, deleted_at = now(), updated_at = now()
WHERE user_id = @user_id AND id = @id AND deleted_at IS NULL;

-- name: VocabularyChanges :many
SELECT * FROM vocabulary_items WHERE user_id = @user_id AND revision > @after_revision ORDER BY revision LIMIT @max_rows;

-- name: VocabularySnapshotPage :many
-- Live items as of head revision H, in id order. Later changes reach the client through catch-up.
SELECT * FROM vocabulary_items
WHERE user_id = @user_id AND deleted_at IS NULL AND revision <= @snapshot_revision AND id > @after_id
ORDER BY id LIMIT @max_rows;

-- name: ExportVocabularyPage :many
SELECT * FROM vocabulary_items WHERE user_id = @user_id AND deleted_at IS NULL AND id > @after_id ORDER BY id LIMIT @max_rows;

-- name: NextLearningCompactionOwner :one
SELECT user_id FROM vocabulary_items WHERE deleted_at IS NOT NULL AND deleted_at < now() - interval '90 days' LIMIT 1;

-- name: CompactVocabularyTombstones :many
-- Bounded ctid batches with the predicate repeated on the outer side (the TRD 01 §6.10 pattern).
DELETE FROM vocabulary_items
WHERE ctid = ANY (ARRAY(
    SELECT v.ctid FROM vocabulary_items v
    WHERE v.user_id = @user_id::uuid AND v.deleted_at < now() - interval '90 days'
    LIMIT @batch_size
)) AND user_id = @user_id::uuid AND deleted_at < now() - interval '90 days'
RETURNING deleted_revision;

-- name: RaiseTombstoneHorizon :exec
UPDATE learning_sync_heads SET tombstone_horizon = GREATEST(tombstone_horizon, @horizon::bigint) WHERE user_id = @user_id;

-- name: DeleteExpiredLearningMutations :execrows
DELETE FROM learning_mutations
WHERE ctid = ANY (ARRAY(
    SELECT m.ctid FROM learning_mutations m WHERE m.created_at < now() - interval '30 days' LIMIT @batch_size
)) AND created_at < now() - interval '30 days';

-- name: DeleteRetiredWriterMutations :execrows
DELETE FROM learning_mutations
WHERE ctid = ANY (ARRAY(
    SELECT m.ctid FROM learning_mutations m
    JOIN learning_sync_writers w ON w.user_id = m.user_id AND w.writer_id = m.writer_id
    WHERE w.retired_at IS NOT NULL
    LIMIT @batch_size
));

-- name: DeleteEmptyRetiredWriters :execrows
DELETE FROM learning_sync_writers
WHERE ctid = ANY (ARRAY(
    SELECT w.ctid FROM learning_sync_writers w
    WHERE w.retired_at IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM learning_mutations m WHERE m.user_id = w.user_id AND m.writer_id = w.writer_id)
    LIMIT @batch_size
)) AND retired_at IS NOT NULL;

-- name: PurgeVocabularyBatch :execrows
DELETE FROM vocabulary_items
WHERE ctid = ANY (ARRAY(
    SELECT v.ctid FROM vocabulary_items v WHERE v.user_id = @user_id::uuid LIMIT @batch_size
)) AND user_id = @user_id::uuid;

-- name: PurgeLearningMutationsBatch :execrows
DELETE FROM learning_mutations
WHERE ctid = ANY (ARRAY(
    SELECT m.ctid FROM learning_mutations m WHERE m.user_id = @user_id::uuid LIMIT @batch_size
)) AND user_id = @user_id::uuid;

-- name: RetireAllLearningWriters :exec
UPDATE learning_sync_writers SET retired_at = now() WHERE user_id = @user_id AND retired_at IS NULL;

-- name: PurgeEmptyLearningWritersBatch :execrows
DELETE FROM learning_sync_writers
WHERE ctid = ANY (ARRAY(
    SELECT w.ctid FROM learning_sync_writers w
    WHERE w.user_id = @user_id::uuid AND NOT EXISTS (
      SELECT 1 FROM learning_mutations m WHERE m.user_id = w.user_id AND m.writer_id = w.writer_id)
    LIMIT @batch_size
)) AND user_id = @user_id::uuid;

-- name: DeleteLearningHead :execrows
DELETE FROM learning_sync_heads WHERE user_id = @user_id;

-- name: HasLearningRows :one
SELECT EXISTS (SELECT 1 FROM vocabulary_items v WHERE v.user_id = @user_id::uuid)
    OR EXISTS (SELECT 1 FROM learning_mutations m WHERE m.user_id = @user_id::uuid)
    OR EXISTS (SELECT 1 FROM learning_sync_writers w WHERE w.user_id = @user_id::uuid) AS remaining;

-- name: InsertExportChunk :exec
INSERT INTO account_export_chunks (operation_id, seq, final, key_id, sealed) VALUES (@operation_id, @seq, @final, @key_id, @sealed);

-- name: GetExportChunk :one
SELECT * FROM account_export_chunks WHERE operation_id = @operation_id AND seq = @seq;

-- name: DeleteExportChunks :exec
DELETE FROM account_export_chunks WHERE operation_id = ANY(@operation_ids::uuid[]);
