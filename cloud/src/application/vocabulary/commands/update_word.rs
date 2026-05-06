use chrono::{NaiveDate, Utc};
use uuid::Uuid;

use crate::application::vocabulary::dto::vocabulary_dto::VocabularyWordResponse;
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::domain::vocabulary::repositories::vocabulary_repository::VocabularyRepository;

pub struct UpdateWordCommand {
    pub id: Uuid,
    pub user_id: Uuid,
    pub word: Option<String>,
    pub vietnamese_meaning: Option<String>,
    pub phonetic: Option<String>,
    pub examples: Option<Vec<String>>,
    pub date: Option<String>,
}

pub async fn handle(
    cmd: UpdateWordCommand,
    repo: &impl VocabularyRepository,
) -> AppResult<VocabularyWordResponse> {
    let mut word = repo
        .find_by_id(cmd.id, cmd.user_id)
        .await
        .map_err(AppError::Internal)?
        .ok_or_else(|| AppError::NotFound(format!("word {}", cmd.id)))?;

    if let Some(w) = cmd.word {
        word.word = w;
    }
    if let Some(m) = cmd.vietnamese_meaning {
        word.vietnamese_meaning = m;
    }
    if let Some(p) = cmd.phonetic {
        word.phonetic = Some(p);
    }
    if let Some(e) = cmd.examples {
        word.examples = e;
    }
    if let Some(d) = cmd.date {
        word.date = NaiveDate::parse_from_str(&d, "%Y-%m-%d")
            .map_err(|_| AppError::Validation("invalid date format".to_string()))?;
    }
    word.updated_at = Utc::now();

    repo.update(&word).await.map_err(AppError::Internal)?;

    Ok(word.into())
}
