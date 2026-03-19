use secrecy::ExposeSecret;
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use std::time::Duration;
use tracing::info;

use super::config::DatabaseConfig;

/// Create a PostgreSQL connection pool.
///
/// Applies production-safe settings: connection limits, timeouts, and connection lifetime.
/// Runs pending migrations automatically on startup.
pub async fn init_database(config: &DatabaseConfig) -> Result<PgPool, anyhow::Error> {
    let pool = PgPoolOptions::new()
        .max_connections(config.max_connections)
        .min_connections(config.min_connections)
        .acquire_timeout(Duration::from_secs(config.acquire_timeout_secs))
        .idle_timeout(Duration::from_secs(config.idle_timeout_secs))
        .max_lifetime(Duration::from_secs(config.max_lifetime_secs))
        .connect(config.url.expose_secret())
        .await?;

    info!(
        max_connections = config.max_connections,
        min_connections = config.min_connections,
        "PostgreSQL connection pool initialized"
    );

    // Run migrations
    sqlx::migrate!("./migrations").run(&pool).await?;
    info!("Database migrations applied successfully");

    Ok(pool)
}
