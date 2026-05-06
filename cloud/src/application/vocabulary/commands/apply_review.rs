use chrono::Utc;
use uuid::Uuid;

use crate::application::vocabulary::dto::vocabulary_dto::VocabularyWordResponse;
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::domain::vocabulary::repositories::vocabulary_repository::VocabularyRepository;

pub struct ApplyReviewCommand {
    pub id: Uuid,
    pub user_id: Uuid,
    /// Quality: 0 = fail, 1 = hard, 2 = ok, 3 = easy
    pub quality: u8,
}

pub async fn handle(
    cmd: ApplyReviewCommand,
    repo: &impl VocabularyRepository,
) -> AppResult<VocabularyWordResponse> {
    let mut word = repo
        .find_by_id(cmd.id, cmd.user_id)
        .await
        .map_err(AppError::Internal)?
        .ok_or_else(|| AppError::NotFound(format!("word {}", cmd.id)))?;

    // Map quality 0-3 → SM-2 grade 0-5
    let grade = match cmd.quality {
        0 => 0u8,
        1 => 3,
        2 => 4,
        _ => 5,
    };

    // SM-2 algorithm
    if grade < 3 {
        // Failed recall — reset
        word.review_count = 0;
        word.interval_days = 1;
    } else {
        word.review_count += 1;
        word.interval_days = match word.review_count {
            1 => 1,
            2 => 6,
            _ => (word.interval_days as f64 * word.ease_factor).round() as i32,
        };
        // Update ease factor
        let q = grade as f64;
        word.ease_factor =
            (word.ease_factor + (0.1 - (5.0 - q) * (0.08 + (5.0 - q) * 0.02))).max(1.3);
    }

    let today = Utc::now().date_naive();
    word.next_review_date = Some(today + chrono::Duration::days(word.interval_days as i64));
    word.updated_at = Utc::now();

    repo.update(&word).await.map_err(AppError::Internal)?;

    Ok(word.into())
}
