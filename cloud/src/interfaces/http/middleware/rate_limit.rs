use axum::extract::{ConnectInfo, Request, State};
use axum::middleware::Next;
use axum::response::Response;
use std::net::SocketAddr;
use std::time::Duration;

use crate::application::identity::ports::cache_service::CacheService;
use crate::bootstrap::app_state::AppState;
use crate::common::error::AppError;

/// Redis-based sliding-window rate limiter.
///
/// Uses the client IP as the rate-limit key.
pub async fn rate_limit_middleware(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Result<Response, AppError> {
    let ip = request
        .extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map(|ci| ci.0.ip().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    let key = format!("rl:{ip}");
    let window = Duration::from_secs(1);

    let count = state
        .cache_service
        .increment(&key, window)
        .await
        .unwrap_or(0);

    if count > state.config.rate_limit.requests_per_second {
        return Err(AppError::RateLimitExceeded);
    }

    Ok(next.run(request).await)
}
