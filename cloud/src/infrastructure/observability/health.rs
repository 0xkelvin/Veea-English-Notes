use serde::Serialize;
use sqlx::PgPool;
use redis::aio::ConnectionManager;
use redis::AsyncCommands;

/// Health check response body.
#[derive(Debug, Serialize)]
pub struct HealthResponse {
    pub status: &'static str,
    pub database: ComponentHealth,
    pub redis: ComponentHealth,
}

#[derive(Debug, Serialize)]
pub struct ComponentHealth {
    pub status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

impl ComponentHealth {
    fn up() -> Self {
        Self {
            status: "up",
            message: None,
        }
    }

    fn down(msg: String) -> Self {
        Self {
            status: "down",
            message: Some(msg),
        }
    }
}

/// Check all infrastructure dependencies and return a health summary.
pub async fn check_health(db: &PgPool, redis: &ConnectionManager) -> HealthResponse {
    let database = check_database(db).await;
    let redis_health = check_redis(redis).await;

    let overall = if database.status == "up" && redis_health.status == "up" {
        "healthy"
    } else {
        "degraded"
    };

    HealthResponse {
        status: overall,
        database,
        redis: redis_health,
    }
}

async fn check_database(db: &PgPool) -> ComponentHealth {
    match sqlx::query_scalar::<_, i32>("SELECT 1")
        .fetch_one(db)
        .await
    {
        Ok(_) => ComponentHealth::up(),
        Err(e) => ComponentHealth::down(e.to_string()),
    }
}

async fn check_redis(redis: &ConnectionManager) -> ComponentHealth {
    let mut conn = redis.clone();
    match conn.get::<&str, Option<String>>("__health_check__").await {
        Ok(_) => ComponentHealth::up(),
        Err(e) => ComponentHealth::down(e.to_string()),
    }
}
