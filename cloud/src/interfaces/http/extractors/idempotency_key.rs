use axum::extract::FromRequestParts;
use axum::http::request::Parts;

use crate::common::error::AppError;
use crate::common::idempotency::IdempotencyKey;

pub const IDEMPOTENCY_KEY_HEADER: &str = "idempotency-key";

/// Axum extractor that reads the `Idempotency-Key` header.
pub struct IdempotencyKeyExtractor(pub IdempotencyKey);

impl<S: Send + Sync> FromRequestParts<S> for IdempotencyKeyExtractor {
    type Rejection = AppError;

    async fn from_request_parts(
        parts: &mut Parts,
        _state: &S,
    ) -> Result<Self, Self::Rejection> {
        let key = parts
            .headers
            .get(IDEMPOTENCY_KEY_HEADER)
            .and_then(|v| v.to_str().ok())
            .ok_or_else(|| {
                AppError::Validation("Missing Idempotency-Key header".to_string())
            })?;

        Ok(IdempotencyKeyExtractor(IdempotencyKey::new(key)))
    }
}
