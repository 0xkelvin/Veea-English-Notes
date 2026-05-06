CREATE TABLE vocabulary_words (
    id              UUID PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    word            TEXT NOT NULL,
    vietnamese_meaning TEXT NOT NULL,
    examples        JSONB NOT NULL DEFAULT '[]',
    date            DATE NOT NULL,
    review_count    INTEGER NOT NULL DEFAULT 0,
    ease_factor     DOUBLE PRECISION NOT NULL DEFAULT 2.5,
    interval_days   INTEGER NOT NULL DEFAULT 0,
    next_review_date DATE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_vocabulary_words_user_id ON vocabulary_words(user_id);
CREATE INDEX idx_vocabulary_words_due ON vocabulary_words(user_id, next_review_date);
