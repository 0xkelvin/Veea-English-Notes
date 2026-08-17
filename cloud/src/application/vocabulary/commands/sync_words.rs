use tracing::instrument;
use uuid::Uuid;

use crate::application::vocabulary::dto::word_dto::{SyncRequest, SyncResponse, WordPayload};
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::domain::vocabulary::entities::word::Word;
use crate::domain::vocabulary::errors::VocabularyError;
use crate::domain::vocabulary::repositories::word_repository::WordRepository;

/// Largest batch a client may push in one call.
pub const MAX_BATCH: usize = 500;

/// Largest page of changes returned in one pull.
pub const MAX_PULL: i64 = 500;

#[derive(Debug)]
pub struct SyncWordsCommand {
    pub user_id: Uuid,
    pub request: SyncRequest,
}

/// Applies the client's pending changes and returns everything it has not
/// seen yet.
///
/// The pull deliberately runs *after* the push, and its cursor is the server
/// clock rather than the client's, so a device immediately sees the canonical
/// result of its own upload — including any write that lost a conflict.
#[instrument(skip_all, fields(user_id = %command.user_id, pushed = command.request.changes.len()))]
pub async fn handle<R: WordRepository>(
    command: SyncWordsCommand,
    repo: &R,
) -> AppResult<SyncResponse> {
    let SyncWordsCommand { user_id, request } = command;

    if request.changes.len() > MAX_BATCH {
        return Err(AppError::Validation(
            VocabularyError::BatchTooLarge(request.changes.len()).to_string(),
        ));
    }

    // Validate the whole batch before writing any of it, so a single bad row
    // cannot leave the upload half-applied.
    let words = request
        .changes
        .into_iter()
        .map(|payload| payload.into_domain(user_id))
        .collect::<Result<Vec<Word>, VocabularyError>>()
        .map_err(|error| AppError::Validation(error.to_string()))?;

    let accepted = if words.is_empty() {
        Vec::new()
    } else {
        repo.upsert_batch(user_id, &words).await?
    };

    // Ask for one extra row to detect whether another page is waiting, without
    // a second count query.
    let mut changes = repo
        .changes_since(user_id, request.since, MAX_PULL + 1)
        .await?;

    let has_more = changes.len() as i64 > MAX_PULL;
    if has_more {
        changes.truncate(MAX_PULL as usize);
    }

    // The cursor is the last row actually returned, never "now": rows written
    // between the query and the response would otherwise be skipped forever.
    let server_time = changes
        .last()
        .map(|change| change.server_updated_at)
        .or(request.since)
        .unwrap_or_else(chrono::Utc::now);

    Ok(SyncResponse {
        accepted,
        changes: changes
            .iter()
            .map(|change| WordPayload::from(&change.word))
            .collect(),
        server_time,
        has_more,
    })
}
