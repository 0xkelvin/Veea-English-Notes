use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;
use validator::Validate;

use crate::domain::vocabulary::entities::vocabulary_word::VocabularyWord;

// ── Request DTOs ──────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize, Validate)]
pub struct CreateWordRequest {
    #[validate(length(min = 1, max = 200))]
    pub word: String,
    #[validate(length(min = 1, max = 500))]
    pub vietnamese_meaning: String,
    pub phonetic: Option<String>,
    pub examples: Option<Vec<String>>,
    pub date: String, // YYYY-MM-DD
}

#[derive(Debug, Deserialize, Validate)]
pub struct UpdateWordRequest {
    #[validate(length(min = 1, max = 200))]
    pub word: Option<String>,
    #[validate(length(min = 1, max = 500))]
    pub vietnamese_meaning: Option<String>,
    pub phonetic: Option<String>,
    pub examples: Option<Vec<String>>,
    pub date: Option<String>, // YYYY-MM-DD
}

// ── AI Suggest DTOs ───────────────────────────────────────────────────────────

#[derive(Debug, Deserialize, Validate)]
pub struct SuggestWordRequest {
    #[validate(length(min = 1, max = 200))]
    pub word: String,
}

#[derive(Debug, Serialize)]
pub struct SuggestWordResponse {
    pub word: String,
    pub vietnamese_meaning: String,
    pub phonetic: String,
    pub examples: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct ReviewRequest {
    /// SM-2 quality score: 0 (fail) – 3 (easy)
    pub quality: u8,
}

// ── Response DTOs ─────────────────────────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct VocabularyWordResponse {
    pub id: Uuid,
    pub word: String,
    pub vietnamese_meaning: String,
    pub phonetic: Option<String>,
    pub examples: Vec<String>,
    pub date: String,
    pub review_count: i32,
    pub ease_factor: f64,
    pub interval_days: i32,
    pub next_review_date: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl From<VocabularyWord> for VocabularyWordResponse {
    fn from(w: VocabularyWord) -> Self {
        Self {
            id: w.id,
            word: w.word,
            vietnamese_meaning: w.vietnamese_meaning,
            phonetic: w.phonetic,
            examples: w.examples,
            date: w.date.to_string(),
            review_count: w.review_count,
            ease_factor: w.ease_factor,
            interval_days: w.interval_days,
            next_review_date: w.next_review_date.map(|d| d.to_string()),
            created_at: w.created_at,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct VocabularyListResponse {
    pub items: Vec<VocabularyWordResponse>,
    pub total: usize,
}
