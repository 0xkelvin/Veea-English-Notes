use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::StatusCode;
use axum::middleware::Next;
use axum::response::Response;
use std::time::Duration;

use crate::application::identity::ports::cache_service::CacheService;
use crate::bootstrap::app_state::AppState;

const IDEMPOTENCY_KEY_HEADER: &str = "idempotency-key";
const IDEMPOTENCY_TTL: Duration = Duration::from_secs(86_400); // 24 hours

/// Opt-in idempotency middleware.
///
/// When the `Idempotency-Key` header is present on a mutating request,
/// the response is cached in Redis so that retries return the same result.
pub async fn idempotency_middleware(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Response {
    // Only activate if header is present
    let key = match request.headers().get(IDEMPOTENCY_KEY_HEADER) {
        Some(v) => match v.to_str() {
            Ok(k) => k.to_string(),
            Err(_) => return next.run(request).await,
        },
        None => return next.run(request).await,
    };

    let cache_key = format!("idempotency:{key}");

    // Check cache for existing response
    if let Ok(Some(cached)) = state.cache_service.get(&cache_key).await
        && let Ok(parsed) = serde_json::from_str::<CachedResponse>(&cached)
    {
        let status =
            StatusCode::from_u16(parsed.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
        return Response::builder()
            .status(status)
            .header("content-type", "application/json")
            .header("x-idempotent-replay", "true")
            .body(Body::from(parsed.body))
            .unwrap_or_else(|_| {
                Response::builder()
                    .status(StatusCode::INTERNAL_SERVER_ERROR)
                    .body(Body::empty())
                    .unwrap()
            });
    }

    // Execute handler
    let response = next.run(request).await;
    let status = response.status();

    // Only cache successful responses
    if status.is_success() {
        // Buffer the body so we can cache it
        let (parts, body) = response.into_parts();
        match axum::body::to_bytes(body, 1_048_576).await {
            Ok(bytes) => {
                let body_str = String::from_utf8_lossy(&bytes).to_string();
                let cached = CachedResponse {
                    status: status.as_u16(),
                    body: body_str.clone(),
                };
                if let Ok(json) = serde_json::to_string(&cached) {
                    let _ = state.cache_service.set(&cache_key, &json, IDEMPOTENCY_TTL).await;
                }
                Response::from_parts(parts, Body::from(bytes))
            }
            Err(_) => {
                // If we can't buffer, return error
                Response::builder()
                    .status(StatusCode::INTERNAL_SERVER_ERROR)
                    .body(Body::empty())
                    .unwrap()
            }
        }
    } else {
        response
    }
}

#[derive(serde::Serialize, serde::Deserialize)]
struct CachedResponse {
    status: u16,
    body: String,
}
