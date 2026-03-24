use axum::extract::{Request, State};
use axum::middleware::Next;
use axum::response::Response;

use crate::application::identity::ports::jwt_service::JwtService;
use crate::bootstrap::app_state::AppState;
use crate::common::auth_context::AuthContext;
use crate::common::error::AppError;

/// Middleware that validates a JWT Bearer token and injects [AuthContext]
/// into request extensions.
///
/// Apply to route groups that require authentication.
/// Handlers then read `Extension<AuthContext>` cheaply.
pub async fn require_auth(
    State(state): State<AppState>,
    mut request: Request,
    next: Next,
) -> Result<Response, AppError> {
    let header = request
        .headers()
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

    let ctx = AuthContext {
        user_id: claims.sub,
        email: claims.email,
        role: claims.role,
        token_id: claims.jti,
    };

    request.extensions_mut().insert(ctx);
    Ok(next.run(request).await)
}
