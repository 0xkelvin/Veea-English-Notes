use tracing::instrument;

use crate::application::identity::dto::auth_dto::{AuthTokensResponse, RegisterUserResponse};
use crate::application::identity::ports::clock::Clock;
use crate::application::identity::ports::id_generator::IdGenerator;
use crate::application::identity::ports::jwt_service::{AccessTokenClaims, JwtService};
use crate::application::identity::ports::password_hasher::PasswordHasher;
use crate::application::identity::transaction::{
    begin_tx, PgPool, TransactionalOutboxRepository, TransactionalRefreshTokenRepository,
    TransactionalUserRepository,
};
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::domain::identity::entities::user::User;
use crate::domain::identity::events::IdentityDomainEvent;
use crate::domain::identity::repositories::outbox_repository::{OutboxEvent, OutboxStatus};
use crate::domain::identity::repositories::user_repository::UserRepository;
use crate::domain::identity::value_objects::email::Email;
use crate::domain::identity::value_objects::password_hash::PasswordHash;
use crate::domain::identity::value_objects::refresh_token::RefreshToken;

/// Input for the RegisterUser command.
#[derive(Debug)]
pub struct RegisterUserCommand {
    pub email: String,
    pub password: String,
}

/// Register a new user account.
///
/// 1. Validate input
/// 2. Check email uniqueness
/// 3. Hash password
/// 4. Create User aggregate (raises UserRegistered event)
/// 5. Within a single transaction: persist user + outbox event
/// 6. Issue access + refresh tokens
#[allow(clippy::too_many_arguments)]
#[instrument(skip_all, fields(email = %cmd.email))]
pub async fn handle(
    cmd: RegisterUserCommand,
    user_repo: &impl UserRepository,
    user_repo_tx: &impl TransactionalUserRepository,
    outbox_repo_tx: &impl TransactionalOutboxRepository,
    refresh_repo_tx: &impl TransactionalRefreshTokenRepository,
    pool: &PgPool,
    hasher: &impl PasswordHasher,
    jwt: &impl JwtService,
    clock: &impl Clock,
    id_gen: &impl IdGenerator,
) -> AppResult<RegisterUserResponse> {
    // 1. Validate email format
    let email = Email::new(&cmd.email).map_err(|e| AppError::Validation(e.to_string()))?;

    // 2. Validate password length
    if cmd.password.len() < 8 || cmd.password.len() > 128 {
        return Err(AppError::Validation(
            "password must be between 8 and 128 characters".to_string(),
        ));
    }

    // 3. Check uniqueness
    if user_repo.find_by_email(&email).await?.is_some() {
        return Err(AppError::Conflict(format!(
            "email '{}' is already registered",
            email
        )));
    }

    // 4. Hash password
    let hash_str = hasher.hash_password(&cmd.password).await?;
    let password_hash =
        PasswordHash::new(hash_str).map_err(|e| AppError::Validation(e.to_string()))?;

    // 5. Create aggregate
    let now = clock.now();
    let user_id = id_gen.new_id();
    let mut user = User::register(user_id, email, password_hash, now);

    // 6. Collect domain events
    let events = user.take_events();

    // 7. Transactional write: user + outbox events + refresh token
    let mut tx = begin_tx(pool).await?;

    user_repo_tx.insert_tx(&mut tx, &user).await?;

    for event in &events {
        let outbox = build_outbox_event(event, id_gen, now)?;
        outbox_repo_tx.insert_tx(&mut tx, &outbox).await?;
    }

    // Issue refresh token
    let refresh_token_raw = generate_refresh_token();
    let refresh_token_hash = hash_refresh_token(&refresh_token_raw);
    let refresh_expiry = now + chrono::Duration::seconds(604_800); // 7 days
    let refresh =
        RefreshToken::new(id_gen.new_id(), user_id, refresh_token_hash, refresh_expiry, now);
    refresh_repo_tx.insert_tx(&mut tx, &refresh).await?;

    tx.commit().await?;

    // 8. Issue access token
    let token_id = id_gen.new_id();
    let access_expiry = now + chrono::Duration::seconds(900);
    let claims = AccessTokenClaims {
        sub: user_id,
        email: user.email.as_str().to_string(),
        role: user.role.as_str().to_string(),
        jti: token_id,
        iat: now,
        exp: access_expiry,
    };
    let access_token = jwt.create_access_token(&claims)?;

    Ok(RegisterUserResponse {
        user_id,
        email: user.email.as_str().to_string(),
        tokens: AuthTokensResponse::new(access_token, refresh_token_raw, 900),
    })
}

fn build_outbox_event(
    event: &IdentityDomainEvent,
    id_gen: &impl IdGenerator,
    now: chrono::DateTime<chrono::Utc>,
) -> Result<OutboxEvent, anyhow::Error> {
    Ok(OutboxEvent {
        id: id_gen.new_id(),
        aggregate_type: event.aggregate_type().to_string(),
        aggregate_id: event.aggregate_id(),
        event_type: event.event_type().to_string(),
        payload: serde_json::to_value(event)?,
        metadata: serde_json::json!({}),
        status: OutboxStatus::Pending,
        occurred_at: now,
        published_at: None,
        retry_count: 0,
    })
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
