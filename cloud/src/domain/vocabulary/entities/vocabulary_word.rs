use chrono::{DateTime, NaiveDate, Utc};
use uuid::Uuid;

/// A vocabulary word owned by a user.
#[derive(Debug, Clone)]
pub struct VocabularyWord {
    pub id: Uuid,
    pub user_id: Uuid,
    pub word: String,
    pub vietnamese_meaning: String,
    pub phonetic: Option<String>,
    pub examples: Vec<String>,
    pub date: NaiveDate,
    // SM-2 spaced repetition fields
    pub review_count: i32,
    pub ease_factor: f64,
    pub interval_days: i32,
    pub next_review_date: Option<NaiveDate>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}
