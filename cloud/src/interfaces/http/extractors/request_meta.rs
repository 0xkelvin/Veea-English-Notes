use axum::extract::FromRequestParts;
use axum::http::request::Parts;

use crate::common::correlation::CorrelationId;
use crate::common::request_id::RequestId;

/// Aggregated per-request metadata set by middleware.
pub struct RequestMeta {
    pub request_id: RequestId,
    pub correlation_id: CorrelationId,
}

impl<S: Send + Sync> FromRequestParts<S> for RequestMeta {
    type Rejection = std::convert::Infallible;

    async fn from_request_parts(
        parts: &mut Parts,
        _state: &S,
    ) -> Result<Self, Self::Rejection> {
        let request_id = parts
            .extensions
            .get::<RequestId>()
            .cloned()
            .unwrap_or_else(RequestId::generate);

        let correlation_id = parts
            .extensions
            .get::<CorrelationId>()
            .cloned()
            .unwrap_or_else(CorrelationId::generate);

        Ok(RequestMeta {
            request_id,
            correlation_id,
        })
    }
}
