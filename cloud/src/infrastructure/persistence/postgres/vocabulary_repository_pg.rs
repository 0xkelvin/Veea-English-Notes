use chrono::{DateTime, NaiveDate, Utc};
use sqlx::{FromRow, PgPool};
use uuid::Uuid;

use crate::domain::vocabulary::entities::vocabulary_word::VocabularyWord;
use crate::domain::vocabulary::repositories::vocabulary_repository::VocabularyRepository;

#[derive(Debug, FromRow)]
struct VocabularyWordRow {
    pub id: Uuid,
    pub user_id: Uuid,
    pub word: String,
    pub vietnamese_meaning: String,
    pub phonetic: Option<String>,
    pub examples: serde_json::Value,
    pub date: NaiveDate,
    pub review_count: i32,
    pub ease_factor: f64,
    pub interval_days: i32,
    pub next_review_date: Option<NaiveDate>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl VocabularyWordRow {
    fn into_domain(self) -> VocabularyWord {
        let examples: Vec<String> = serde_json::from_value(self.examples).unwrap_or_default();
        VocabularyWord {
            id: self.id,
            user_id: self.user_id,
            word: self.word,
            vietnamese_meaning: self.vietnamese_meaning,
            phonetic: self.phonetic,
            examples,
            date: self.date,
            review_count: self.review_count,
            ease_factor: self.ease_factor,
            interval_days: self.interval_days,
            next_review_date: self.next_review_date,
            created_at: self.created_at,
            updated_at: self.updated_at,
        }
    }
}

pub struct PgVocabularyRepository {
    pool: PgPool,
}

impl PgVocabularyRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

impl VocabularyRepository for PgVocabularyRepository {
    async fn find_by_id(
        &self,
        id: Uuid,
        user_id: Uuid,
    ) -> Result<Option<VocabularyWord>, anyhow::Error> {
        let row = sqlx::query_as::<_, VocabularyWordRow>(
            "SELECT id, user_id, word, vietnamese_meaning, phonetic, examples, date,
                    review_count, ease_factor, interval_days, next_review_date,
                    created_at, updated_at
             FROM vocabulary_words WHERE id = $1 AND user_id = $2",
        )
        .bind(id)
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await?;

        Ok(row.map(VocabularyWordRow::into_domain))
    }

    async fn list_by_user(&self, user_id: Uuid) -> Result<Vec<VocabularyWord>, anyhow::Error> {
        let rows = sqlx::query_as::<_, VocabularyWordRow>(
            "SELECT id, user_id, word, vietnamese_meaning, phonetic, examples, date,
                    review_count, ease_factor, interval_days, next_review_date,
                    created_at, updated_at
             FROM vocabulary_words WHERE user_id = $1 ORDER BY created_at DESC",
        )
        .bind(user_id)
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(VocabularyWordRow::into_domain)
            .collect())
    }

    async fn list_due(
        &self,
        user_id: Uuid,
        today: NaiveDate,
    ) -> Result<Vec<VocabularyWord>, anyhow::Error> {
        let rows = sqlx::query_as::<_, VocabularyWordRow>(
            "SELECT id, user_id, word, vietnamese_meaning, phonetic, examples, date,
                    review_count, ease_factor, interval_days, next_review_date,
                    created_at, updated_at
             FROM vocabulary_words
             WHERE user_id = $1
               AND (next_review_date IS NULL OR next_review_date <= $2)
             ORDER BY next_review_date ASC NULLS FIRST",
        )
        .bind(user_id)
        .bind(today)
        .fetch_all(&self.pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(VocabularyWordRow::into_domain)
            .collect())
    }

    async fn insert(&self, word: &VocabularyWord) -> Result<(), anyhow::Error> {
        let examples = serde_json::to_value(&word.examples)?;
        sqlx::query(
            "INSERT INTO vocabulary_words
             (id, user_id, word, vietnamese_meaning, phonetic, examples, date,
              review_count, ease_factor, interval_days, next_review_date,
              created_at, updated_at)
             VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)",
        )
        .bind(word.id)
        .bind(word.user_id)
        .bind(&word.word)
        .bind(&word.vietnamese_meaning)
        .bind(&word.phonetic)
        .bind(examples)
        .bind(word.date)
        .bind(word.review_count)
        .bind(word.ease_factor)
        .bind(word.interval_days)
        .bind(word.next_review_date)
        .bind(word.created_at)
        .bind(word.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn update(&self, word: &VocabularyWord) -> Result<(), anyhow::Error> {
        let examples = serde_json::to_value(&word.examples)?;
        sqlx::query(
            "UPDATE vocabulary_words SET
               word = $1, vietnamese_meaning = $2, phonetic = $3, examples = $4, date = $5,
               review_count = $6, ease_factor = $7, interval_days = $8,
               next_review_date = $9, updated_at = $10
             WHERE id = $11 AND user_id = $12",
        )
        .bind(&word.word)
        .bind(&word.vietnamese_meaning)
        .bind(&word.phonetic)
        .bind(examples)
        .bind(word.date)
        .bind(word.review_count)
        .bind(word.ease_factor)
        .bind(word.interval_days)
        .bind(word.next_review_date)
        .bind(word.updated_at)
        .bind(word.id)
        .bind(word.user_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn delete(&self, id: Uuid, user_id: Uuid) -> Result<bool, anyhow::Error> {
        let result = sqlx::query("DELETE FROM vocabulary_words WHERE id = $1 AND user_id = $2")
            .bind(id)
            .bind(user_id)
            .execute(&self.pool)
            .await?;
        Ok(result.rows_affected() > 0)
    }
}
