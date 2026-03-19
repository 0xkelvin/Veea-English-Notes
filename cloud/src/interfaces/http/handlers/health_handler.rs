use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use serde::Serialize;

use crate::bootstrap::app_state::AppState;

/// Kubernetes liveness probe — always returns 200.
pub async fn liveness() -> StatusCode {
    StatusCode::OK
}

/// Readiness probe — checks that database and Redis are reachable.
pub async fn readiness(State(state): State<AppState>) -> impl IntoResponse {
    let db_ok = sqlx::query("SELECT 1")
        .execute(&state.db)
        .await
        .is_ok();

    let mut redis_conn = state.redis.clone();
    let redis_ok: bool = redis::cmd("PING")
        .query_async::<String>(&mut redis_conn)
        .await
        .is_ok();

    let status = if db_ok && redis_ok {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };

    (
        status,
        Json(ReadinessResponse {
            status: if db_ok && redis_ok {
                "healthy"
            } else {
                "degraded"
            },
            checks: HealthChecks {
                database: if db_ok { "up" } else { "down" },
                redis: if redis_ok { "up" } else { "down" },
            },
        }),
    )
}

#[derive(Serialize)]
struct ReadinessResponse {
    status: &'static str,
    checks: HealthChecks,
}

#[derive(Serialize)]
struct HealthChecks {
    database: &'static str,
    redis: &'static str,
}
