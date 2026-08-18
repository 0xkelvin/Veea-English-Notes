use axum::Json;
use axum::extract::State;
use axum::response::IntoResponse;
use validator::Validate;

use crate::application::identity::commands::{change_identifier, change_password, delete_account};
use crate::application::identity::dto::auth_dto::{
    ChangeIdentifierRequest, ChangePasswordRequest, DeleteAccountRequest,
};
use crate::application::vocabulary::queries::export_words;
use crate::bootstrap::app_state::AppState;
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::interfaces::http::extractors::auth_user::AuthUser;
use crate::interfaces::http::response::{ApiResponse, no_content};

/// DELETE /api/v1/users/me
///
/// Permanently deletes the caller's account and everything it owns.
pub async fn delete_me(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Json(body): Json<DeleteAccountRequest>,
) -> AppResult<axum::response::Response> {
    body.validate()
        .map_err(|e| AppError::Validation(e.to_string()))?;

    delete_account::handle(
        delete_account::DeleteAccountCommand {
            user_id: ctx.user_id,
            password: body.password,
        },
        state.user_repo.as_ref(),
        state.user_repo.as_ref(),
        state.outbox_repo.as_ref(),
        state.refresh_token_repo.as_ref(),
        &state.db,
        state.password_hasher.as_ref(),
        &state.clock,
        &state.id_gen,
    )
    .await?;

    Ok(no_content().into_response())
}

/// PUT /api/v1/users/me/password
///
/// Succeeds with 204 and no body: there is nothing useful to return, and the
/// caller's sessions have been revoked, so it must sign in again.
pub async fn change_my_password(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Json(body): Json<ChangePasswordRequest>,
) -> AppResult<axum::response::Response> {
    body.validate()
        .map_err(|e| AppError::Validation(e.to_string()))?;

    change_password::handle(
        change_password::ChangePasswordCommand {
            user_id: ctx.user_id,
            current_password: body.current_password,
            new_password: body.new_password,
        },
        state.user_repo.as_ref(),
        state.user_repo.as_ref(),
        state.outbox_repo.as_ref(),
        state.refresh_token_repo.as_ref(),
        &state.db,
        state.password_hasher.as_ref(),
        &state.clock,
        &state.id_gen,
    )
    .await?;

    Ok(no_content().into_response())
}

/// PUT /api/v1/users/me/identifier
///
/// Sets the email address or phone number on the caller's account, returning
/// the updated profile so the client can show both identifiers.
pub async fn change_my_identifier(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Json(body): Json<ChangeIdentifierRequest>,
) -> AppResult<axum::response::Response> {
    body.validate()
        .map_err(|e| AppError::Validation(e.to_string()))?;

    let profile = change_identifier::handle(
        change_identifier::ChangeIdentifierCommand {
            user_id: ctx.user_id,
            identifier: body.identifier,
            password: body.password,
        },
        state.user_repo.as_ref(),
        state.user_repo.as_ref(),
        state.outbox_repo.as_ref(),
        &state.db,
        state.password_hasher.as_ref(),
        &state.clock,
        &state.id_gen,
    )
    .await?;

    Ok(ApiResponse::ok(profile).into_response())
}

/// GET /api/v1/users/me/export
///
/// Returns every word the account holds, for the user to keep.
pub async fn export_my_words(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
) -> AppResult<axum::response::Response> {
    use crate::application::identity::ports::clock::Clock;

    let export = export_words::handle(
        export_words::ExportWordsQuery {
            user_id: ctx.user_id,
        },
        state.word_repo.as_ref(),
        state.clock.now(),
    )
    .await?;

    Ok(ApiResponse::ok(export).into_response())
}
