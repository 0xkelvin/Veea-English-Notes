use redis::aio::ConnectionManager;
use secrecy::ExposeSecret;
use tracing::info;

use super::config::RedisConfig;

/// Initialize a Redis connection manager.
///
/// Uses a managed connection that automatically reconnects on failure,
/// suitable for production workloads with high connection churn.
pub async fn init_redis(config: &RedisConfig) -> Result<ConnectionManager, anyhow::Error> {
    let url: &str = config.url.expose_secret();
    let client = redis::Client::open(url)?;
    let manager = ConnectionManager::new(client).await?;

    info!("Redis connection manager initialized");
    Ok(manager)
}
