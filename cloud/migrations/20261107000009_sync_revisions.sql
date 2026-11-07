-- A timestamp alone cannot page a batch sharing one transaction timestamp.
ALTER TABLE words ADD COLUMN sync_revision BIGSERIAL NOT NULL;
CREATE INDEX idx_words_owner_revision ON words(user_id, sync_revision);
