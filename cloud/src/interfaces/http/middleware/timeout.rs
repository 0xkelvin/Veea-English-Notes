use std::time::Duration;

use axum::http::StatusCode;
use tower_http::timeout::TimeoutLayer;

/// Build a request-level timeout layer.
pub fn timeout_layer(secs: u64) -> TimeoutLayer {
    TimeoutLayer::with_status_code(StatusCode::GATEWAY_TIMEOUT, Duration::from_secs(secs))
}
