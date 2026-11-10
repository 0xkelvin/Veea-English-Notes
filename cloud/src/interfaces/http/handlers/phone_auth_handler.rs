use crate::interfaces::http::{
    extractors::auth_user::AuthUser,
    response::{ApiResponse, no_content},
};
use crate::{
    application::identity::phone_auth,
    bootstrap::app_state::AppState,
    common::{error::AppError, result::AppResult},
    domain::identity::repositories::user_repository::UserRepository,
};
use axum::{
    Json,
    extract::{ConnectInfo, State},
    response::IntoResponse,
};
use serde::Deserialize;
use std::net::SocketAddr;
use uuid::Uuid;

#[derive(Deserialize)]
pub struct RequestCode {
    phone: String,
}
#[derive(Deserialize)]
pub struct VerifyCode {
    challenge_id: Uuid,
    code: String,
}

pub async fn request(
    State(state): State<AppState>,
    ip: Option<axum::Extension<ConnectInfo<SocketAddr>>>,
    Json(body): Json<RequestCode>,
) -> AppResult<axum::response::Response> {
    if body.phone.len() > 40 {
        return Err(AppError::Validation("Enter a valid phone number.".into()));
    }
    let ip = ip
        .map(|i| i.0.0.ip().to_string())
        .unwrap_or_else(|| "unknown".into());
    Ok(ApiResponse::ok(
        phone_auth::request_challenge(
            &state.db,
            state.otp_delivery.as_ref(),
            &body.phone,
            "signin",
            None,
            &ip,
        )
        .await?,
    )
    .into_response())
}
pub async fn verify(
    State(state): State<AppState>,
    Json(body): Json<VerifyCode>,
) -> AppResult<axum::response::Response> {
    let phone = phone_auth::consume_challenge(
        &state.db,
        state.otp_delivery.as_ref(),
        body.challenge_id,
        &body.code,
        "signin",
        None,
    )
    .await?;
    let result = phone_auth::sign_in_verified(
        phone,
        &state.db,
        state.user_repo.as_ref(),
        state.refresh_token_repo.as_ref(),
        state.outbox_repo.as_ref(),
        state.password_hasher.as_ref(),
        state.jwt_service.as_ref(),
        &state.clock,
        &state.id_gen,
        state.config.jwt.access_token_expiry_secs,
        state.config.jwt.refresh_token_expiry_secs,
    )
    .await?;
    Ok(ApiResponse::ok(result).into_response())
}
pub async fn request_delete(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    ip: Option<axum::Extension<ConnectInfo<SocketAddr>>>,
) -> AppResult<axum::response::Response> {
    let user = state
        .user_repo
        .find_by_id(ctx.user_id)
        .await?
        .ok_or(AppError::Unauthorized)?;
    let phone = user
        .phone
        .ok_or_else(|| AppError::Validation("This account uses password confirmation.".into()))?;
    let ip = ip
        .map(|i| i.0.0.ip().to_string())
        .unwrap_or_else(|| "unknown".into());
    Ok(ApiResponse::ok(
        phone_auth::request_challenge(
            &state.db,
            state.otp_delivery.as_ref(),
            phone.as_str(),
            "delete",
            Some(ctx.user_id),
            &ip,
        )
        .await?,
    )
    .into_response())
}
pub async fn delete_verified(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Json(body): Json<VerifyCode>,
) -> AppResult<axum::response::Response> {
    phone_auth::delete_verified_account(
        &state.db,
        state.otp_delivery.as_ref(),
        ctx.user_id,
        body.challenge_id,
        &body.code,
        state.user_repo.as_ref(),
        state.outbox_repo.as_ref(),
        &state.clock,
        &state.id_gen,
    )
    .await?;
    Ok(no_content().into_response())
}

#[derive(Deserialize)]
pub struct DeletionReceipt {
    user_id: Uuid,
    challenge_id: Uuid,
}

/// POST /auth/deletion-receipt — public. Answers only "did this exact
/// deletion challenge delete this account?", so a client whose deletion
/// response was lost does not have to treat a later 401 as proof.
pub async fn deletion_receipt(
    State(state): State<AppState>,
    Json(body): Json<DeletionReceipt>,
) -> AppResult<axum::response::Response> {
    let deleted =
        phone_auth::deletion_confirmed(&state.db, body.user_id, body.challenge_id).await?;
    Ok(ApiResponse::ok(serde_json::json!({ "deleted": deleted })).into_response())
}

#[derive(Deserialize)]
pub struct NewPhoneCode {
    proof_id: Uuid,
    new_phone: String,
}

fn peer(ip: Option<axum::Extension<ConnectInfo<SocketAddr>>>) -> String {
    ip.map(|i| i.0.0.ip().to_string())
        .unwrap_or_else(|| "unknown".into())
}

/// POST /users/me/phone-change/current-code
pub async fn change_current_code(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    ip: Option<axum::Extension<ConnectInfo<SocketAddr>>>,
) -> AppResult<axum::response::Response> {
    Ok(ApiResponse::ok(
        phone_auth::request_current_phone_code(
            &state.db,
            state.otp_delivery.as_ref(),
            ctx.user_id,
            &peer(ip),
        )
        .await?,
    )
    .into_response())
}

/// POST /users/me/phone-change/current-verify
pub async fn change_current_verify(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Json(body): Json<VerifyCode>,
) -> AppResult<axum::response::Response> {
    Ok(ApiResponse::ok(
        phone_auth::verify_current_phone(
            &state.db,
            state.otp_delivery.as_ref(),
            ctx.user_id,
            body.challenge_id,
            &body.code,
        )
        .await?,
    )
    .into_response())
}

/// POST /users/me/phone-change/new-code
pub async fn change_new_code(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    ip: Option<axum::Extension<ConnectInfo<SocketAddr>>>,
    Json(body): Json<NewPhoneCode>,
) -> AppResult<axum::response::Response> {
    if body.new_phone.len() > 40 {
        return Err(AppError::Validation("Enter a valid phone number.".into()));
    }
    Ok(ApiResponse::ok(
        phone_auth::request_new_phone_code(
            &state.db,
            state.otp_delivery.as_ref(),
            ctx.user_id,
            body.proof_id,
            &body.new_phone,
            &peer(ip),
        )
        .await?,
    )
    .into_response())
}

/// POST /users/me/phone-change/confirm
pub async fn change_confirm(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Json(body): Json<VerifyCode>,
) -> AppResult<axum::response::Response> {
    let result = phone_auth::confirm_phone_change(
        &state.db,
        state.otp_delivery.as_ref(),
        ctx.user_id,
        body.challenge_id,
        &body.code,
        state.user_repo.as_ref(),
        state.refresh_token_repo.as_ref(),
        state.outbox_repo.as_ref(),
        state.jwt_service.as_ref(),
        &state.clock,
        &state.id_gen,
        state.config.jwt.access_token_expiry_secs,
        state.config.jwt.refresh_token_expiry_secs,
    )
    .await?;
    Ok(ApiResponse::ok(result).into_response())
}
