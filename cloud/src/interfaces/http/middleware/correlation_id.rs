use axum::extract::Request;
use axum::http::HeaderValue;
use axum::middleware::Next;
use axum::response::Response;

use crate::common::correlation::{CorrelationId, CORRELATION_ID_HEADER};

/// Middleware that extracts or generates a correlation ID for distributed tracing.
pub async fn correlation_id_middleware(mut request: Request, next: Next) -> Response {
    let id = request
        .headers()
        .get(CORRELATION_ID_HEADER)
        .and_then(|v| v.to_str().ok())
        .map(CorrelationId::new)
        .unwrap_or_else(CorrelationId::generate);

    request.extensions_mut().insert(id.clone());

    let mut response = next.run(request).await;

    if let Ok(val) = HeaderValue::from_str(id.as_str()) {
        response.headers_mut().insert(CORRELATION_ID_HEADER, val);
    }

    response
}
