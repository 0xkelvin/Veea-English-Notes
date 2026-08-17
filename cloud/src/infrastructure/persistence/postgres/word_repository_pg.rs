use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::domain::vocabulary::entities::word::Word;
use crate::domain::vocabulary::repositories::word_repository::{WordChange, WordRepository};

use super::models::{WordChangeRow, WordRow};

/// Postgres-backed implementation of `WordRepository`.
pub struct PgWordRepository {
    pool: PgPool,
}

impl PgWordRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

impl WordRepository for PgWordRepository {
    async fn upsert_batch(
        &self,
        user_id: Uuid,
        words: &[Word],
    ) -> Result<Vec<Uuid>, anyhow::Error> {
        if words.is_empty() {
            return Ok(Vec::new());
        }

        let mut tx = self.pool.begin().await?;
        let mut accepted = Vec::with_capacity(words.len());

        for word in words {
            // Two guards live in the ON CONFLICT clause:
            //
            //   words.user_id = EXCLUDED.user_id
            //     Word ids come from clients, so a caller could send an id
            //     that already belongs to somebody else. Without this the
            //     upsert would overwrite another user's row. The predicate
            //     makes that a silent no-op instead.
            //
            //   EXCLUDED.updated_at > words.updated_at
            //     Last-write-wins. A stale retry does not clobber a newer
            //     edit made on another device.
            //
            // RETURNING only yields a row when the insert or update actually
            // happened, which is exactly the acknowledgement set.
            let returned: Option<(Uuid,)> = sqlx::query_as(
                "INSERT INTO words (
                     id, user_id, word, meaning, pronunciation, part_of_speech,
                     source, examples, tags, day, is_deleted,
                     created_at, updated_at, server_updated_at
                 )
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, now())
                 ON CONFLICT (id) DO UPDATE SET
                     word              = EXCLUDED.word,
                     meaning           = EXCLUDED.meaning,
                     pronunciation     = EXCLUDED.pronunciation,
                     part_of_speech    = EXCLUDED.part_of_speech,
                     source            = EXCLUDED.source,
                     examples          = EXCLUDED.examples,
                     tags              = EXCLUDED.tags,
                     day               = EXCLUDED.day,
                     is_deleted        = EXCLUDED.is_deleted,
                     updated_at        = EXCLUDED.updated_at,
                     server_updated_at = now()
                 WHERE words.user_id = EXCLUDED.user_id
                   AND EXCLUDED.updated_at > words.updated_at
                 RETURNING id",
            )
            .bind(word.id)
            .bind(user_id)
            .bind(word.word.as_str())
            .bind(word.meaning.as_str())
            .bind(word.pronunciation.as_deref())
            .bind(word.part_of_speech.map(|p| p.as_str()))
            .bind(word.source.as_deref())
            .bind(serde_json::to_value(&word.examples)?)
            .bind(serde_json::to_value(&word.tags)?)
            .bind(word.day)
            .bind(word.is_deleted)
            .bind(word.created_at)
            .bind(word.updated_at)
            .fetch_optional(&mut *tx)
            .await?;

            if let Some((id,)) = returned {
                accepted.push(id);
                continue;
            }

            // No row came back: either the write was stale, or the id belongs
            // to another user. A stale write is a normal, expected outcome, so
            // it is reported as accepted — the client's copy is already
            // superseded and the pull half of this same request carries the
            // winning version back to it. A foreign id is a genuine problem
            // and is left out so the client stops retrying it.
            let owned: Option<(bool,)> =
                sqlx::query_as("SELECT user_id = $2 FROM words WHERE id = $1")
                    .bind(word.id)
                    .bind(user_id)
                    .fetch_optional(&mut *tx)
                    .await?;

            match owned {
                Some((true,)) => accepted.push(word.id),
                Some((false,)) => tracing::warn!(
                    word_id = %word.id,
                    %user_id,
                    "rejected sync for a word owned by another user"
                ),
                None => tracing::error!(
                    word_id = %word.id,
                    "upsert stored nothing and the row is absent"
                ),
            }
        }

        tx.commit().await?;
        Ok(accepted)
    }

    async fn changes_since(
        &self,
        user_id: Uuid,
        since: Option<DateTime<Utc>>,
        limit: i64,
    ) -> Result<Vec<WordChange>, anyhow::Error> {
        // Tombstones are included on purpose: a deletion is a change other
        // devices have to learn about.
        let rows = sqlx::query_as::<_, WordChangeRow>(
            "SELECT id, user_id, word, meaning, pronunciation, part_of_speech,
                    source, examples, tags, day, is_deleted,
                    created_at, updated_at, server_updated_at
             FROM words
             WHERE user_id = $1
               AND ($2::timestamptz IS NULL OR server_updated_at > $2)
             ORDER BY server_updated_at ASC
             LIMIT $3",
        )
        .bind(user_id)
        .bind(since)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter().map(WordChangeRow::into_domain).collect()
    }

    async fn list(
        &self,
        user_id: Uuid,
        offset: i64,
        limit: i64,
    ) -> Result<(Vec<Word>, u64), anyhow::Error> {
        let total: (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM words WHERE user_id = $1 AND is_deleted = FALSE")
                .bind(user_id)
                .fetch_one(&self.pool)
                .await?;

        let rows = sqlx::query_as::<_, WordRow>(
            "SELECT id, user_id, word, meaning, pronunciation, part_of_speech,
                    source, examples, tags, day, is_deleted, created_at, updated_at
             FROM words
             WHERE user_id = $1 AND is_deleted = FALSE
             ORDER BY day DESC, created_at DESC
             LIMIT $2 OFFSET $3",
        )
        .bind(user_id)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.pool)
        .await?;

        let words = rows
            .into_iter()
            .map(WordRow::into_domain)
            .collect::<Result<Vec<_>, _>>()?;

        Ok((words, total.0 as u64))
    }

    async fn find_by_id(&self, user_id: Uuid, id: Uuid) -> Result<Option<Word>, anyhow::Error> {
        let row = sqlx::query_as::<_, WordRow>(
            "SELECT id, user_id, word, meaning, pronunciation, part_of_speech,
                    source, examples, tags, day, is_deleted, created_at, updated_at
             FROM words
             WHERE id = $1 AND user_id = $2",
        )
        .bind(id)
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await?;

        row.map(WordRow::into_domain).transpose()
    }
}
