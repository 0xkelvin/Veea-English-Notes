use tracing::instrument;

use crate::application::identity::dto::user_dto::UserSummary;
use crate::common::pagination::{PaginatedResponse, PaginationMeta, PaginationParams};
use crate::common::result::AppResult;
use crate::domain::identity::repositories::user_repository::UserRepository;

#[derive(Debug)]
pub struct ListUsersQuery {
    pub pagination: PaginationParams,
}

/// List users with pagination (admin only).
///
/// Authorization is enforced at the handler/middleware level.
/// This query is a pure read operation.
#[instrument(skip_all, fields(page = query.pagination.page, per_page = query.pagination.per_page))]
pub async fn handle<U: UserRepository>(
    query: ListUsersQuery,
    user_repo: &U,
) -> AppResult<PaginatedResponse<UserSummary>> {
    let offset = query.pagination.offset();
    let limit = query.pagination.limit();

    let (users, total) = user_repo.list(offset, limit).await?;

    let data = users.iter().map(UserSummary::from).collect();
    let meta = PaginationMeta::new(query.pagination.page, limit, total);

    Ok(PaginatedResponse { data, meta })
}
