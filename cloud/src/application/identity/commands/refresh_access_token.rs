use tracing::instrument;

use crate::application::identity::dto::auth_dto::AuthTokensResponse;
use crate::application::identity::ports::clock::Clock;
use crate::application::identity::ports::id_generator::IdGenerator;
use crate::application::identity::ports::jwt_service::{AccessTokenClaims, JwtService};
use crate::application::identity::transaction::{
    begin_tx, PgPool, TransactionalRefreshTokenRepository,
};
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::domain::identity::repositories::refresh_token_repository::RefreshTokenRepository;
use crate::domain::identity::repositories::user_repository::UserRepository;
use crate::domain::identity::value_objects::refresh_token::RefreshToken;

#[derive(Debug)]
pub struct RefreshAccessTokenCommand {
    pub refresh_token: String,
}

/// Refresh an access token using a valid refresh token.
///
/// Implements refresh token rotation:
/// 1. Validate the incoming refresh token
/// 2. Revoke the old refresh token
/// 3. Issue a new refresh + access token pair
#[instrument(skip_all)]
pub async fn handle(
    cmd: RefreshAccessTokenCommand,
    user_repo: &impl UserRepository,
    refresh_repo: &impl RefreshTokenRepository,
    refresh_repo_tx: &impl TransactionalRefreshTokenRepository,
    pool: &PgPool,
    jwt: &impl JwtService,
    clock: &impl Clock,
    id_gen: &impl IdGenerator,
) -> AppResult<AuthTokensResponse> {
    let now = clock.now();

    // Hash the incoming token and look it up
    let incoming_hash = hash_refresh_token(&cmd.refresh_token);
    let existing = refresh_repo
        .find_by_token_hash(&incoming_hash)
        .await?
        .ok_or(AppError::Unauthorized)?;

    // Validate
    if existing.is_revoked() {
        return Err(AppError::Unauthorized);
    }
    if existing.is_expired(now) {
        return Err(AppError::Unauthorized);
    }

    // Load user to get current role/email
    let user = user_repo
        .find_by_id(existing.user_id)
        .await?
        .ok_or(AppError::Unauthorized)?;

    user.ensure_active().map_err(|_| AppError::Forbidden)?;

    // Rotate: revoke old, issue new
    let new_refresh_raw = generate_refresh_token();
    let new_refresh_hash = hash_refresh_token(&new_refresh_raw);
    let refresh_expiry = now + chrono::Duration::seconds(604_800);
    let new_refresh = RefreshToken::new(
        id_gen.new_id(),
        user.id,
        new_refresh_hash,
        refresh_expiry,
        now,
    );

    let mut tx = begin_tx(pool).await?;
    refresh_repo_tx.revoke_tx(&mut tx, existing.id, now).await?;
    refresh_repo_tx.insert_tx(&mut tx, &new_refresh).await?;
    tx.commit().await?;

    // Issue access token
    let token_id = id_gen.new_id();
    let access_expiry = now + chrono::Duration::seconds(900);
    let claims = AccessTokenClaims {
        sub: user.id,
        email: user.email.as_str().to_string(),
        role: user.role.as_str().to_string(),
        jti: token_id,
        iat: now,
        exp: access_expiry,
    };
    let access_token = jwt.create_access_token(&claims)?;

    Ok(AuthTokensResponse::new(access_token, new_refresh_raw, 900))
}

fn generate_refresh_token() -> String {
    use base64::Engine;
    let mut bytes = [0u8; 32];
    rand::fill(&mut bytes);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn hash_refresh_token(token: &str) -> String {
    use sha2::Digest;
    let hash = sha2::Sha256::digest(token.as_bytes());
    hex::encode(hash)
}
