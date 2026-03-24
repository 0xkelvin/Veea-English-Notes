use std::sync::Arc;

use redis::aio::ConnectionManager;
use sqlx::PgPool;

use super::config::AppConfig;
use super::messaging::MessagingConnection;
use crate::application::identity::ports::clock::SystemClock;
use crate::application::identity::ports::id_generator::UuidGenerator;
use crate::infrastructure::cache::RedisCacheService;
use crate::infrastructure::persistence::postgres::{
    PgOutboxRepository, PgRefreshTokenRepository, PgUserRepository,
};
use crate::infrastructure::security::{Argon2PasswordHasher, JwtServiceImpl};

/// Central application state shared across all request handlers and background workers.
///
/// This struct is the composition root — it holds all infrastructure handles
/// and is injected into the Axum router as shared state.
///
/// Individual subsystems receive only the handles they need
/// (via ports/traits), not the entire AppState.
#[derive(Clone)]
pub struct AppState {
    pub config: Arc<AppConfig>,
    pub db: PgPool,
    pub redis: ConnectionManager,
    pub messaging: Arc<MessagingConnection>,
    // ── Application services ────────────────────────────────────
    pub user_repo: Arc<PgUserRepository>,
    pub refresh_token_repo: Arc<PgRefreshTokenRepository>,
    pub outbox_repo: Arc<PgOutboxRepository>,
    pub password_hasher: Arc<Argon2PasswordHasher>,
    pub jwt_service: Arc<JwtServiceImpl>,
    pub cache_service: Arc<RedisCacheService>,
    pub clock: SystemClock,
    pub id_gen: UuidGenerator,
}

impl AppState {
    pub fn new(
        config: Arc<AppConfig>,
        db: PgPool,
        redis: ConnectionManager,
        messaging: MessagingConnection,
    ) -> Self {
        let user_repo = Arc::new(PgUserRepository::new(db.clone()));
        let refresh_token_repo = Arc::new(PgRefreshTokenRepository::new(db.clone()));
        let outbox_repo = Arc::new(PgOutboxRepository::new(db.clone()));
        let password_hasher = Arc::new(Argon2PasswordHasher::new());
        let jwt_service = Arc::new(JwtServiceImpl::new(
            &config.jwt.secret,
            config.jwt.issuer.clone(),
            config.jwt.audience.clone(),
        ));
        let cache_service = Arc::new(RedisCacheService::new(redis.clone()));

        Self {
            config,
            db,
            redis,
            messaging: Arc::new(messaging),
            user_repo,
            refresh_token_repo,
            outbox_repo,
            password_hasher,
            jwt_service,
            cache_service,
            clock: SystemClock,
            id_gen: UuidGenerator,
        }
    }
}
