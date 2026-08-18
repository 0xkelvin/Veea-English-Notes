use axum::Json;
use axum::extract::{Query, State};
use axum::response::IntoResponse;

use crate::application::vocabulary::commands::sync_words;
use crate::application::vocabulary::dto::word_dto::SyncRequest;
use crate::application::vocabulary::queries::list_words;
use crate::bootstrap::app_state::AppState;
use crate::common::pagination::PaginationParams;
use crate::common::result::AppResult;
use crate::interfaces::http::extractors::auth_user::AuthUser;
use crate::interfaces::http::response::ApiResponse;

/// POST /api/v1/vocabulary/sync
///
/// Push local changes and pull everything the caller has not seen, in one
/// round trip. The owner is taken from the validated token, never the body.
pub async fn sync(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Json(request): Json<SyncRequest>,
) -> AppResult<axum::response::Response> {
    let command = sync_words::SyncWordsCommand {
        user_id: ctx.user_id,
        request,
    };

    let response = sync_words::handle(command, state.word_repo.as_ref()).await?;

    Ok(ApiResponse::ok(response).into_response())
}

/// GET /api/v1/vocabulary/words
pub async fn list(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Query(pagination): Query<PaginationParams>,
) -> AppResult<axum::response::Response> {
    let query = list_words::ListWordsQuery {
        user_id: ctx.user_id,
        pagination,
    };

    let page = list_words::handle(query, state.word_repo.as_ref()).await?;

    Ok(ApiResponse::ok(page).into_response())
}
