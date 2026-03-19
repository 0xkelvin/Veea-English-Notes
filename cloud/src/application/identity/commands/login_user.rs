use tracing::instrument;

use crate::application::identity::dto::auth_dto::AuthTokensResponse;
use crate::application::identity::ports::clock::Clock;
use crate::application::identity::ports::id_generator::IdGenerator;
use crate::application::identity::ports::jwt_service::{AccessTokenClaims, JwtService};
use crate::application::identity::ports::password_hasher::PasswordHasher;
use crate::application::identity::transaction::{
    begin_tx, PgPool, TransactionalRefreshTokenRepository,
};
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::domain::identity::repositories::user_repository::UserRepository;
use crate::domain::identity::value_objects::email::Email;
use crate::domain::identity::value_objects::refresh_token::RefreshToken;

#[derive(Debug)]
pub struct LoginUserCommand {
    pub email: String,
    pub password: String,
}

/// Authenticate a user and issue tokens.
///
/// 1. Validate email format
/// 2. Look up user by email
/// 3. Verify password
/// 4. Check account is active
/// 5. Issue access + refresh tokens
#[instrument(skip_all, fields(email = %cmd.email))]
pub async fn handle(
    cmd: LoginUserCommand,
    user_repo: &impl UserRepository,
    refresh_repo_tx: &impl TransactionalRefreshTokenRepository,
    pool: &PgPool,
    hasher: &impl PasswordHasher,
    jwt: &impl JwtService,
    clock: &impl Clock,
    id_gen: &impl IdGenerator,
) -> AppResult<AuthTokensResponse> {
    let email = Email::new(&cmd.email).map_err(|e| AppError::Validation(e.to_string()))?;

    // Find user — return generic "invalid credentials" to avoid user enumeration
    let user = user_repo
        .find_by_email(&email)
        .await?
        .ok_or(AppError::Unauthorized)?;

    // Verify password
    let valid = hasher
        .verify_password(&cmd.password, user.password_hash.as_str())
        .await?;
    if !valid {
        return Err(AppError::Unauthorized);
    }

    // Check account status
    user.ensure_active().map_err(|_| AppError::Forbidden)?;

    // Issue tokens
    let now = clock.now();
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

    // Refresh token
    let refresh_token_raw = generate_refresh_token();
    let refresh_token_hash = hash_refresh_token(&refresh_token_raw);
    let refresh_expiry = now + chrono::Duration::seconds(604_800);
    let refresh = RefreshToken::new(
        id_gen.new_id(),
        user.id,
        refresh_token_hash,
        refresh_expiry,
        now,
    );

    let mut tx = begin_tx(pool).await?;
    refresh_repo_tx.insert_tx(&mut tx, &refresh).await?;
    tx.commit().await?;

    Ok(AuthTokensResponse::new(access_token, refresh_token_raw, 900))
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
