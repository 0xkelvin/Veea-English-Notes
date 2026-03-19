use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::Serialize;

/// Unified error type for the entire application.
///
/// Maps domain/application errors to HTTP responses while keeping
/// internal details out of client-facing messages.
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("Validation error: {0}")]
    Validation(String),

    #[error("Authentication required")]
    Unauthorized,

    #[error("Insufficient permissions")]
    Forbidden,

    #[error("Resource not found: {0}")]
    NotFound(String),

    #[error("Conflict: {0}")]
    Conflict(String),

    #[error("Idempotent request already processed")]
    IdempotentReplay { status: StatusCode, body: String },

    #[error("Rate limit exceeded")]
    RateLimitExceeded,

    #[error("Request timeout")]
    Timeout,

    #[error("Internal server error")]
    Internal(#[source] anyhow::Error),
}

/// Client-facing error response body.
#[derive(Debug, Serialize)]
pub struct ErrorResponse {
    pub error: ErrorBody,
}

#[derive(Debug, Serialize)]
pub struct ErrorBody {
    pub code: &'static str,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<serde_json::Value>,
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, code, message) = match &self {
            AppError::Validation(msg) => (StatusCode::BAD_REQUEST, "VALIDATION_ERROR", msg.clone()),
            AppError::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                "UNAUTHORIZED",
                "Authentication required".to_string(),
            ),
            AppError::Forbidden => (
                StatusCode::FORBIDDEN,
                "FORBIDDEN",
                "Insufficient permissions".to_string(),
            ),
            AppError::NotFound(msg) => (StatusCode::NOT_FOUND, "NOT_FOUND", msg.clone()),
            AppError::Conflict(msg) => (StatusCode::CONFLICT, "CONFLICT", msg.clone()),
            AppError::IdempotentReplay { status, body } => {
                return Response::builder()
                    .status(*status)
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from(body.clone()))
                    .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response());
            }
            AppError::RateLimitExceeded => (
                StatusCode::TOO_MANY_REQUESTS,
                "RATE_LIMIT_EXCEEDED",
                "Too many requests".to_string(),
            ),
            AppError::Timeout => (
                StatusCode::GATEWAY_TIMEOUT,
                "TIMEOUT",
                "Request timed out".to_string(),
            ),
            AppError::Internal(err) => {
                // Log the full error chain internally; never expose it to the client.
                tracing::error!(error = ?err, "Internal server error");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "INTERNAL_ERROR",
                    "An internal error occurred".to_string(),
                )
            }
        };

        let body = ErrorResponse {
            error: ErrorBody {
                code,
                message,
                details: None,
            },
        };

        (status, axum::Json(body)).into_response()
    }
}

/// Allow `anyhow::Error` to be converted to `AppError::Internal` transparently.
impl From<anyhow::Error> for AppError {
    fn from(err: anyhow::Error) -> Self {
        AppError::Internal(err)
    }
}

impl From<sqlx::Error> for AppError {
    fn from(err: sqlx::Error) -> Self {
        match &err {
            sqlx::Error::RowNotFound => AppError::NotFound("Record not found".to_string()),
            sqlx::Error::Database(db_err) => {
                // Unique constraint violation → conflict
                if db_err.code().as_deref() == Some("23505") {
                    AppError::Conflict("Resource already exists".to_string())
                } else {
                    AppError::Internal(err.into())
                }
            }
            _ => AppError::Internal(err.into()),
        }
    }
}
