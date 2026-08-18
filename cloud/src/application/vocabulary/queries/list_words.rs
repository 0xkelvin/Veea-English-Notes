use tracing::instrument;
use uuid::Uuid;

use crate::application::vocabulary::dto::word_dto::WordPayload;
use crate::common::pagination::{PaginatedResponse, PaginationMeta, PaginationParams};
use crate::common::result::AppResult;
use crate::domain::vocabulary::repositories::word_repository::WordRepository;

#[derive(Debug)]
pub struct ListWordsQuery {
    pub user_id: Uuid,
    pub pagination: PaginationParams,
}

/// A page of the caller's own vocabulary, newest day first.
///
/// Tombstones are excluded — this is a reading endpoint, not a sync feed.
#[instrument(skip_all, fields(user_id = %query.user_id))]
pub async fn handle<R: WordRepository>(
    query: ListWordsQuery,
    repo: &R,
) -> AppResult<PaginatedResponse<WordPayload>> {
    let ListWordsQuery {
        user_id,
        pagination,
    } = query;

    let (words, total) = repo
        .list(
            user_id,
            pagination.offset() as i64,
            pagination.limit() as i64,
        )
        .await?;

    Ok(PaginatedResponse {
        data: words.iter().map(WordPayload::from).collect(),
        meta: PaginationMeta::new(pagination.page, pagination.limit(), total),
    })
}
