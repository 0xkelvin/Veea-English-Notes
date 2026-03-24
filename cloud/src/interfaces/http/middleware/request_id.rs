use axum::extract::Request;
use axum::http::HeaderValue;
use axum::middleware::Next;
use axum::response::Response;

use crate::common::request_id::{RequestId, REQUEST_ID_HEADER};

/// Middleware that generates (or propagates) a unique request ID.
///
/// - Reads from incoming `x-request-id` header if present.
/// - Otherwise generates a UUIDv4.
/// - Inserts into request extensions and echoes in the response header.
pub async fn request_id_middleware(mut request: Request, next: Next) -> Response {
    let id = request
        .headers()
        .get(REQUEST_ID_HEADER)
        .and_then(|v| v.to_str().ok())
        .map(RequestId::new)
        .unwrap_or_else(RequestId::generate);

    request.extensions_mut().insert(id.clone());

    let mut response = next.run(request).await;

    if let Ok(val) = HeaderValue::from_str(id.as_str()) {
        response.headers_mut().insert(REQUEST_ID_HEADER, val);
    }

    response
}
