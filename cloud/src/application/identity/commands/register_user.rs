use crate::application::identity::commands::support::{build_outbox_event, generate_refresh_token, hash_refresh_token};
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
use crate::domain::identity::repositories::user_repository::UserRepository;
use crate::domain::identity::value_objects::identifier::Identifier;
use crate::domain::identity::value_objects::password_hash::PasswordHash;
use crate::domain::identity::value_objects::refresh_token::RefreshToken;

/// Input for the RegisterUser command.
#[derive(Debug)]
pub struct RegisterUserCommand {
    /// An email address or a phone number; the server decides which.
    pub identifier: String,
    pub password: String,
}

/// Register a new user account.
///
/// 1. Validate input
/// 2. Check identifier uniqueness
/// 3. Hash password
/// 4. Create User aggregate (raises UserRegistered event)
/// 5. Within a single transaction: persist user + outbox event
/// 6. Issue access + refresh tokens
#[allow(clippy::too_many_arguments)]
#[instrument(skip_all, fields(identifier_kind = tracing::field::Empty))]
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
    // 1. Parse the identifier, which decides whether this is an email or a
    //    phone account.
    let identifier =
        Identifier::parse(&cmd.identifier).map_err(|e| AppError::Validation(e.to_string()))?;
    // Recorded rather than the value itself: an identifier is personal data
    // and does not belong in logs.
    tracing::Span::current().record("identifier_kind", identifier.kind());

    // 2. Validate password length
    if cmd.password.len() < 8 || cmd.password.len() > 128 {
        return Err(AppError::Validation(
            "password must be between 8 and 128 characters".to_string(),
        ));
    }

    // 3. Check uniqueness. The unique index is the real guarantee; this only
    //    turns the common case into a clear 409 instead of a constraint error.
    if user_repo.find_by_identifier(&identifier).await?.is_some() {
        return Err(AppError::Conflict(
            "that email or phone number is already registered".to_string(),
        ));
    }

    // 4. Hash password
    let hash_str = hasher.hash_password(&cmd.password).await?;
    let password_hash =
        PasswordHash::new(hash_str).map_err(|e| AppError::Validation(e.to_string()))?;

    // 5. Create aggregate
    let now = clock.now();
    let user_id = id_gen.new_id();
    let mut user = User::register(user_id, identifier, password_hash, now);

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
        email: user.primary_identifier(),
        role: user.role.as_str().to_string(),
        jti: token_id,
        iat: now,
        exp: access_expiry,
    };
    let access_token = jwt.create_access_token(&claims)?;

    Ok(RegisterUserResponse {
        user_id,
        identifier: user.primary_identifier(),
        tokens: AuthTokensResponse::new(access_token, refresh_token_raw, 900),
    })
}



