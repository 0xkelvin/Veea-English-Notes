use secrecy::SecretString;
use serde::Deserialize;
use std::sync::Arc;

/// Top-level application configuration loaded from environment variables.
///
/// Structured hierarchically to keep concerns separated and allow
/// independent validation of each subsystem's settings.
#[derive(Debug, Clone, Deserialize)]
pub struct AppConfig {
    pub app: ServerConfig,
    pub database: DatabaseConfig,
    pub redis: RedisConfig,
    pub jwt: JwtConfig,
    pub messaging: MessagingConfig,
    pub observability: ObservabilityConfig,
    pub outbox: OutboxConfig,
    pub rate_limit: RateLimitConfig,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ServerConfig {
    pub name: String,
    pub env: AppEnvironment,
    pub host: String,
    pub port: u16,
    pub workers: usize,
    pub request_timeout_secs: u64,
    pub body_limit_bytes: usize,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum AppEnvironment {
    Development,
    Staging,
    Production,
}

impl AppEnvironment {
    pub fn is_production(&self) -> bool {
        matches!(self, AppEnvironment::Production)
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct DatabaseConfig {
    pub url: SecretString,
    pub max_connections: u32,
    pub min_connections: u32,
    pub acquire_timeout_secs: u64,
    pub idle_timeout_secs: u64,
    pub max_lifetime_secs: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RedisConfig {
    pub url: SecretString,
    pub pool_size: u32,
}

#[derive(Debug, Clone, Deserialize)]
pub struct JwtConfig {
    pub secret: SecretString,
    pub issuer: String,
    pub audience: String,
    pub access_token_expiry_secs: i64,
    pub refresh_token_expiry_secs: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MessagingConfig {
    pub backend: MessagingBackend,
    pub nats_url: String,
    pub kafka_brokers: String,
    pub kafka_group_id: String,
    pub kafka_client_id: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum MessagingBackend {
    Nats,
    Kafka,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ObservabilityConfig {
    pub otlp_endpoint: String,
    pub service_name: String,
    pub enabled: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct OutboxConfig {
    pub poll_interval_ms: u64,
    pub batch_size: i64,
    pub max_retries: i32,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RateLimitConfig {
    pub requests_per_second: u64,
    pub burst: u64,
}

impl AppConfig {
    /// Load configuration from environment variables.
    ///
    /// Uses a flat ENV mapping with prefixes to build the hierarchical config.
    pub fn from_env() -> Result<Arc<Self>, anyhow::Error> {
        let config = AppConfig {
            app: ServerConfig {
                name: env_or("APP_NAME", "english-notes-cloud"),
                env: match env_or("APP_ENV", "development").as_str() {
                    "production" => AppEnvironment::Production,
                    "staging" => AppEnvironment::Staging,
                    _ => AppEnvironment::Development,
                },
                host: env_or("APP_HOST", "0.0.0.0"),
                port: env_or("APP_PORT", "8080").parse()?,
                workers: env_or("APP_WORKERS", "4").parse()?,
                request_timeout_secs: env_or("APP_REQUEST_TIMEOUT_SECS", "30").parse()?,
                body_limit_bytes: env_or("APP_BODY_LIMIT_BYTES", "1048576").parse()?,
            },
            database: DatabaseConfig {
                url: SecretString::from(env_required("DATABASE_URL")?),
                max_connections: env_or("DATABASE_MAX_CONNECTIONS", "20").parse()?,
                min_connections: env_or("DATABASE_MIN_CONNECTIONS", "5").parse()?,
                acquire_timeout_secs: env_or("DATABASE_ACQUIRE_TIMEOUT_SECS", "5").parse()?,
                idle_timeout_secs: env_or("DATABASE_IDLE_TIMEOUT_SECS", "300").parse()?,
                max_lifetime_secs: env_or("DATABASE_MAX_LIFETIME_SECS", "1800").parse()?,
            },
            redis: RedisConfig {
                url: SecretString::from(env_or("REDIS_URL", "redis://localhost:6379")),
                pool_size: env_or("REDIS_POOL_SIZE", "10").parse()?,
            },
            jwt: JwtConfig {
                secret: SecretString::from(env_required("JWT_SECRET")?),
                issuer: env_or("JWT_ISSUER", "english-notes-cloud"),
                audience: env_or("JWT_AUDIENCE", "english-notes-frontend"),
                access_token_expiry_secs: env_or("JWT_ACCESS_TOKEN_EXPIRY_SECS", "900").parse()?,
                refresh_token_expiry_secs: env_or("JWT_REFRESH_TOKEN_EXPIRY_SECS", "604800")
                    .parse()?,
            },
            messaging: MessagingConfig {
                backend: match env_or("MESSAGING_BACKEND", "nats").as_str() {
                    "kafka" => MessagingBackend::Kafka,
                    _ => MessagingBackend::Nats,
                },
                nats_url: env_or("NATS_URL", "nats://localhost:4222"),
                kafka_brokers: env_or("KAFKA_BROKERS", "localhost:9092"),
                kafka_group_id: env_or("KAFKA_GROUP_ID", "english-notes-cloud"),
                kafka_client_id: env_or("KAFKA_CLIENT_ID", "english-notes-cloud"),
            },
            observability: ObservabilityConfig {
                otlp_endpoint: env_or("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317"),
                service_name: env_or("OTEL_SERVICE_NAME", "english-notes-cloud"),
                enabled: env_or("OTEL_ENABLED", "false").parse()?,
            },
            outbox: OutboxConfig {
                poll_interval_ms: env_or("OUTBOX_POLL_INTERVAL_MS", "500").parse()?,
                batch_size: env_or("OUTBOX_BATCH_SIZE", "50").parse()?,
                max_retries: env_or("OUTBOX_MAX_RETRIES", "5").parse()?,
            },
            rate_limit: RateLimitConfig {
                requests_per_second: env_or("RATE_LIMIT_REQUESTS_PER_SECOND", "50").parse()?,
                burst: env_or("RATE_LIMIT_BURST", "100").parse()?,
            },
        };

        Ok(Arc::new(config))
    }
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn env_required(key: &str) -> Result<String, anyhow::Error> {
    std::env::var(key)
        .map_err(|_| anyhow::anyhow!("Required environment variable '{}' is not set", key))
}
