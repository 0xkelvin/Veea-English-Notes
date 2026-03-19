use axum::extract::State;
use axum::response::IntoResponse;
use axum::Json;
use validator::Validate;

use crate::application::identity::commands::{
    login_user, refresh_access_token, register_user, revoke_refresh_token,
};
use crate::application::identity::dto::auth_dto::{
    LoginRequest, LogoutRequest, RefreshTokenRequest, RegisterUserRequest,
};
use crate::bootstrap::app_state::AppState;
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::interfaces::http::extractors::auth_user::AuthUser;
use crate::interfaces::http::response::{no_content, ApiResponse};

/// POST /api/v1/auth/register
pub async fn register(
    State(state): State<AppState>,
    Json(body): Json<RegisterUserRequest>,
) -> AppResult<axum::response::Response> {
    body.validate()
        .map_err(|e| AppError::Validation(e.to_string()))?;

    let cmd = register_user::RegisterUserCommand {
        email: body.email,
        password: body.password,
    };

    let result = register_user::handle(
        cmd,
        state.user_repo.as_ref(),
        state.user_repo.as_ref(),
        state.outbox_repo.as_ref(),
        state.refresh_token_repo.as_ref(),
        &state.db,
        state.password_hasher.as_ref(),
        state.jwt_service.as_ref(),
        &state.clock,
        &state.id_gen,
    )
    .await?;

    Ok(ApiResponse::created(result).into_response())
}

/// POST /api/v1/auth/login
pub async fn login(
    State(state): State<AppState>,
    Json(body): Json<LoginRequest>,
) -> AppResult<axum::response::Response> {
    body.validate()
        .map_err(|e| AppError::Validation(e.to_string()))?;

    let cmd = login_user::LoginUserCommand {
        email: body.email,
        password: body.password,
    };

    let result = login_user::handle(
        cmd,
        state.user_repo.as_ref(),
        state.refresh_token_repo.as_ref(),
        &state.db,
        state.password_hasher.as_ref(),
        state.jwt_service.as_ref(),
        &state.clock,
        &state.id_gen,
    )
    .await?;

    Ok(ApiResponse::ok(result).into_response())
}

/// POST /api/v1/auth/refresh
pub async fn refresh(
    State(state): State<AppState>,
    Json(body): Json<RefreshTokenRequest>,
) -> AppResult<axum::response::Response> {
    body.validate()
        .map_err(|e| AppError::Validation(e.to_string()))?;

    let cmd = refresh_access_token::RefreshAccessTokenCommand {
        refresh_token: body.refresh_token,
    };

    let result = refresh_access_token::handle(
        cmd,
        state.user_repo.as_ref(),
        state.refresh_token_repo.as_ref(),
        state.refresh_token_repo.as_ref(),
        &state.db,
        state.jwt_service.as_ref(),
        &state.clock,
        &state.id_gen,
    )
    .await?;

    Ok(ApiResponse::ok(result).into_response())
}

/// POST /api/v1/auth/logout
pub async fn logout(
    State(state): State<AppState>,
    AuthUser(_ctx): AuthUser,
    Json(body): Json<LogoutRequest>,
) -> AppResult<axum::response::Response> {
    let cmd = revoke_refresh_token::RevokeRefreshTokenCommand {
        refresh_token: body.refresh_token,
    };

    revoke_refresh_token::handle(
        cmd,
        state.refresh_token_repo.as_ref(),
        &state.clock,
    )
    .await?;

    Ok(no_content().into_response())
}
