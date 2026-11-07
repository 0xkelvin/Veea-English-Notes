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

    let method: (String,) = sqlx::query_as("SELECT auth_method FROM users WHERE id = $1")
        .bind(ctx.user_id)
        .fetch_one(&state.db)
        .await?;
    let mut value = serde_json::to_value(profile).map_err(anyhow::Error::from)?;
    value["auth_method"] = serde_json::json!(method.0);
    Ok(ApiResponse::ok(value).into_response())
}
