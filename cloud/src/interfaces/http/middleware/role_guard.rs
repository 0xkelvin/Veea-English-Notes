use axum::extract::Request;
use axum::middleware::Next;
use axum::response::Response;

use crate::common::auth_context::AuthContext;
use crate::common::error::AppError;

/// Middleware that requires the caller to have the `admin` role.
///
/// Must be applied **after** `require_auth` on the same route group.
pub async fn require_admin(request: Request, next: Next) -> Result<Response, AppError> {
    let ctx = request
        .extensions()
        .get::<AuthContext>()
        .ok_or(AppError::Unauthorized)?;

    if !ctx.is_admin() {
        return Err(AppError::Forbidden);
    }

    Ok(next.run(request).await)
}
