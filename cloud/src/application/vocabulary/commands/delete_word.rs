use uuid::Uuid;

use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::domain::vocabulary::repositories::vocabulary_repository::VocabularyRepository;

pub struct DeleteWordCommand {
    pub id: Uuid,
    pub user_id: Uuid,
}

pub async fn handle(
    cmd: DeleteWordCommand,
    repo: &impl VocabularyRepository,
) -> AppResult<()> {
    let deleted = repo
        .delete(cmd.id, cmd.user_id)
        .await
        .map_err(AppError::Internal)?;

    if !deleted {
        return Err(AppError::NotFound(format!("word {}", cmd.id)));
    }

    Ok(())
}
