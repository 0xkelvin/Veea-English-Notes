use chrono::{NaiveDate, Utc};
use uuid::Uuid;

use crate::application::vocabulary::dto::vocabulary_dto::VocabularyWordResponse;
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::domain::vocabulary::entities::vocabulary_word::VocabularyWord;
use crate::domain::vocabulary::repositories::vocabulary_repository::VocabularyRepository;

pub struct CreateWordCommand {
    pub user_id: Uuid,
    pub word: String,
    pub vietnamese_meaning: String,
    pub phonetic: Option<String>,
    pub examples: Vec<String>,
    pub date: String,
}

pub async fn handle(
    cmd: CreateWordCommand,
    repo: &impl VocabularyRepository,
) -> AppResult<VocabularyWordResponse> {
    let date = NaiveDate::parse_from_str(&cmd.date, "%Y-%m-%d").map_err(|_| {
        AppError::Validation("invalid date format, expected YYYY-MM-DD".to_string())
    })?;

    let now = Utc::now();
    let word = VocabularyWord {
        id: Uuid::new_v4(),
        user_id: cmd.user_id,
        word: cmd.word,
        vietnamese_meaning: cmd.vietnamese_meaning,
        phonetic: cmd.phonetic,
        examples: cmd.examples,
        date,
        review_count: 0,
        ease_factor: 2.5,
        interval_days: 0,
        next_review_date: None,
        created_at: now,
        updated_at: now,
    };

    repo.insert(&word)
        .await
        .map_err(|e| AppError::Internal(e))?;

    Ok(word.into())
}
