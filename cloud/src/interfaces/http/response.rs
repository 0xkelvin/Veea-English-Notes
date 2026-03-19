use axum::http::StatusCode;
use axum::response::IntoResponse;
use serde::Serialize;

/// Standard JSON success envelope.
#[derive(Debug, Serialize)]
pub struct ApiResponse<T: Serialize> {
    pub data: T,
}

impl<T: Serialize> ApiResponse<T> {
    pub fn ok(data: T) -> impl IntoResponse {
        (StatusCode::OK, axum::Json(Self { data }))
    }

    pub fn created(data: T) -> impl IntoResponse {
        (StatusCode::CREATED, axum::Json(Self { data }))
    }
}

/// Empty 204 No Content.
pub fn no_content() -> impl IntoResponse {
    StatusCode::NO_CONTENT
}
