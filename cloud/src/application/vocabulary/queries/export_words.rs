use chrono::{DateTime, Utc};
use serde::Serialize;
use tracing::instrument;
use uuid::Uuid;

use crate::application::vocabulary::dto::word_dto::WordPayload;
use crate::common::result::AppResult;
use crate::domain::vocabulary::repositories::word_repository::WordRepository;

/// Everything the account holds, in one document.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WordExport {
    /// Format version, so an importer can tell what it is reading.
    pub version: u32,
    pub exported_at: DateTime<Utc>,
    pub count: usize,
    pub words: Vec<WordPayload>,
}

#[derive(Debug)]
pub struct ExportWordsQuery {
    pub user_id: Uuid,
}

/// Export the caller's vocabulary for download.
///
/// Deliberately unpaginated: a partial export is not an export, and a personal
/// vocabulary is small enough that one document is reasonable. Tombstones are
/// excluded — the user asked for their words, not the record of deletions.
#[instrument(skip_all, fields(user_id = %query.user_id))]
pub async fn handle<R: WordRepository>(
    query: ExportWordsQuery,
    repo: &R,
    now: DateTime<Utc>,
) -> AppResult<WordExport> {
    // An upper bound well past any realistic personal vocabulary, present so
    // a single request cannot be made to read an unbounded amount.
    const MAX_EXPORT: i64 = 100_000;

    let (words, total) = repo.list(query.user_id, 0, MAX_EXPORT).await?;

    if total as i64 > MAX_EXPORT {
        tracing::warn!(
            user_id = %query.user_id,
            total,
            limit = MAX_EXPORT,
            "export truncated"
        );
    }

    Ok(WordExport {
        version: 1,
        exported_at: now,
        count: words.len(),
        words: words.iter().map(WordPayload::from).collect(),
    })
}
