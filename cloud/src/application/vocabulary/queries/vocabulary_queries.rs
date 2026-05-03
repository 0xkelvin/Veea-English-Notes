use chrono::Utc;
use uuid::Uuid;

use crate::application::vocabulary::dto::vocabulary_dto::{VocabularyListResponse, VocabularyWordResponse};
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::domain::vocabulary::repositories::vocabulary_repository::VocabularyRepository;

pub async fn list_words(
    user_id: Uuid,
    repo: &impl VocabularyRepository,
) -> AppResult<VocabularyListResponse> {
    let words = repo
        .list_by_user(user_id)
        .await
        .map_err(AppError::Internal)?;

    let total = words.len();
    let items = words.into_iter().map(VocabularyWordResponse::from).collect();
    Ok(VocabularyListResponse { items, total })
}

pub async fn list_due_words(
    user_id: Uuid,
    repo: &impl VocabularyRepository,
) -> AppResult<VocabularyListResponse> {
    let today = Utc::now().date_naive();
    let words = repo
        .list_due(user_id, today)
        .await
        .map_err(AppError::Internal)?;

    let total = words.len();
    let items = words.into_iter().map(VocabularyWordResponse::from).collect();
    Ok(VocabularyListResponse { items, total })
}

pub async fn get_word(
    id: Uuid,
    user_id: Uuid,
    repo: &impl VocabularyRepository,
) -> AppResult<VocabularyWordResponse> {
    repo.find_by_id(id, user_id)
        .await
        .map_err(AppError::Internal)?
        .map(VocabularyWordResponse::from)
        .ok_or_else(|| AppError::NotFound(format!("word {}", id)))
}
