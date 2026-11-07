use crate::application::identity::{
    commands::support::build_outbox_event,
    ports::clock::Clock,
    transaction::{TransactionalOutboxRepository, TransactionalUserRepository},
};
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
    let phone = phone_auth::consume_challenge(
        &state.db,
        state.otp_delivery.as_ref(),
        body.challenge_id,
        &body.code,
        "delete",
        Some(ctx.user_id),
    )
    .await?;
    let mut user = state
        .user_repo
        .find_by_id(ctx.user_id)
        .await?
        .ok_or(AppError::Unauthorized)?;
    if user.phone.as_ref().map(|p| p.as_str()) != Some(phone.as_str()) {
        return Err(AppError::Forbidden);
    }
    user.mark_deleted(state.clock.now());
    let mut tx = state.db.begin().await?;
    for event in user.take_events() {
        state
            .outbox_repo
            .insert_tx(
                &mut tx,
                &build_outbox_event(&event, &state.id_gen, state.clock.now())?,
            )
            .await?;
    }
    state.user_repo.delete_tx(&mut tx, ctx.user_id).await?;
    tx.commit().await?;
    Ok(no_content().into_response())
}
