use axum::extract::State;
use axum::response::IntoResponse;

use crate::application::identity::queries::get_my_profile;
use crate::bootstrap::app_state::AppState;
use crate::common::result::AppResult;
use crate::interfaces::http::extractors::auth_user::AuthUser;
use crate::interfaces::http::response::ApiResponse;

/// GET /api/v1/users/me
pub async fn get_my_profile(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
) -> AppResult<axum::response::Response> {
    let query = get_my_profile::GetMyProfileQuery {
        user_id: ctx.user_id,
    };

    let profile = get_my_profile::handle(query, state.user_repo.as_ref()).await?;

    Ok(ApiResponse::ok(profile).into_response())
}
