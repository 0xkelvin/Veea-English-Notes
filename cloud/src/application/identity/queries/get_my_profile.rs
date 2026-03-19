use tracing::instrument;
use uuid::Uuid;

use crate::application::identity::dto::user_dto::UserProfileResponse;
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::domain::identity::repositories::user_repository::UserRepository;

#[derive(Debug)]
pub struct GetMyProfileQuery {
    pub user_id: Uuid,
}

/// Retrieve the authenticated user's own profile.
#[instrument(skip_all, fields(user_id = %query.user_id))]
pub async fn handle<U: UserRepository>(
    query: GetMyProfileQuery,
    user_repo: &U,
) -> AppResult<UserProfileResponse> {
    let user = user_repo
        .find_by_id(query.user_id)
        .await?
        .ok_or_else(|| AppError::NotFound("user not found".to_string()))?;

    Ok(UserProfileResponse::from(&user))
}
