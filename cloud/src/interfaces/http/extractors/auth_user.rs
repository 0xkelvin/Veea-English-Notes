use axum::extract::FromRequestParts;
use axum::http::request::Parts;

use crate::application::identity::ports::jwt_service::JwtService;
use crate::bootstrap::app_state::AppState;
use crate::common::auth_context::AuthContext;
use crate::common::error::AppError;

/// Axum extractor that validates JWT Bearer token and yields [AuthContext].
pub struct AuthUser(pub AuthContext);

impl FromRequestParts<AppState> for AuthUser {
    type Rejection = AppError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let header = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .ok_or(AppError::Unauthorized)?;

        let token = header
            .strip_prefix("Bearer ")
            .ok_or(AppError::Unauthorized)?;

        let claims = state
            .jwt_service
            .validate_access_token(token)
            .map_err(|_| AppError::Unauthorized)?;

        Ok(AuthUser(AuthContext {
            user_id: claims.sub,
            email: claims.email,
            role: claims.role,
            token_id: claims.jti,
        }))
    }
}
