use axum::Json;
use axum::extract::{Path, State};
use axum::response::IntoResponse;
use uuid::Uuid;
use validator::Validate;

use crate::application::vocabulary::commands::{
    apply_review, create_word, delete_word, suggest_word, update_word,
};
use crate::application::vocabulary::dto::vocabulary_dto::{
    CreateWordRequest, ReviewRequest, SuggestWordRequest, UpdateWordRequest,
};
use crate::application::vocabulary::queries::vocabulary_queries;
use crate::bootstrap::app_state::AppState;
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::interfaces::http::extractors::auth_user::AuthUser;
use crate::interfaces::http::response::{ApiResponse, no_content};

/// GET /api/v1/vocabulary
pub async fn list_words(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
) -> AppResult<axum::response::Response> {
    let result =
        vocabulary_queries::list_words(ctx.user_id, state.vocabulary_repo.as_ref()).await?;
    Ok(ApiResponse::ok(result).into_response())
}

/// GET /api/v1/vocabulary/due
pub async fn list_due(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
) -> AppResult<axum::response::Response> {
    let result =
        vocabulary_queries::list_due_words(ctx.user_id, state.vocabulary_repo.as_ref()).await?;
    Ok(ApiResponse::ok(result).into_response())
}

/// GET /api/v1/vocabulary/:id
pub async fn get_word(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<axum::response::Response> {
    let result =
        vocabulary_queries::get_word(id, ctx.user_id, state.vocabulary_repo.as_ref()).await?;
    Ok(ApiResponse::ok(result).into_response())
}

/// POST /api/v1/vocabulary
pub async fn create_word(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Json(body): Json<CreateWordRequest>,
) -> AppResult<axum::response::Response> {
    body.validate()
        .map_err(|e| AppError::Validation(e.to_string()))?;

    let cmd = create_word::CreateWordCommand {
        user_id: ctx.user_id,
        word: body.word,
        vietnamese_meaning: body.vietnamese_meaning,
        phonetic: body.phonetic,
        examples: body.examples.unwrap_or_default(),
        date: body.date,
    };

    let result = create_word::handle(cmd, state.vocabulary_repo.as_ref()).await?;
    Ok(ApiResponse::created(result).into_response())
}

/// PUT /api/v1/vocabulary/:id
pub async fn update_word(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdateWordRequest>,
) -> AppResult<axum::response::Response> {
    body.validate()
        .map_err(|e| AppError::Validation(e.to_string()))?;

    let cmd = update_word::UpdateWordCommand {
        id,
        user_id: ctx.user_id,
        word: body.word,
        vietnamese_meaning: body.vietnamese_meaning,
        phonetic: body.phonetic,
        examples: body.examples,
        date: body.date,
    };

    let result = update_word::handle(cmd, state.vocabulary_repo.as_ref()).await?;
    Ok(ApiResponse::ok(result).into_response())
}

/// DELETE /api/v1/vocabulary/:id
pub async fn delete_word(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<axum::response::Response> {
    let cmd = delete_word::DeleteWordCommand {
        id,
        user_id: ctx.user_id,
    };
    delete_word::handle(cmd, state.vocabulary_repo.as_ref()).await?;
    Ok(no_content().into_response())
}

/// POST /api/v1/vocabulary/:id/review
pub async fn apply_review(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Path(id): Path<Uuid>,
    Json(body): Json<ReviewRequest>,
) -> AppResult<axum::response::Response> {
    if body.quality > 3 {
        return Err(AppError::Validation("quality must be 0–3".to_string()));
    }
    let cmd = apply_review::ApplyReviewCommand {
        id,
        user_id: ctx.user_id,
        quality: body.quality,
    };
    let result = apply_review::handle(cmd, state.vocabulary_repo.as_ref()).await?;
    Ok(ApiResponse::ok(result).into_response())
}

/// POST /api/v1/vocabulary/suggest
pub async fn suggest_word(
    _state: State<AppState>,
    AuthUser(_ctx): AuthUser,
    Json(body): Json<SuggestWordRequest>,
) -> AppResult<axum::response::Response> {
    body.validate()
        .map_err(|e| AppError::Validation(e.to_string()))?;
    let result = suggest_word::handle(&body.word).await?;
    Ok(ApiResponse::ok(result).into_response())
}
