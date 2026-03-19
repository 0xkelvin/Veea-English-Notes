use serde::{Deserialize, Serialize};
use uuid::Uuid;
use validator::Validate;

// ── Request DTOs ────────────────────────────────────────────────────

#[derive(Debug, Deserialize, Validate)]
pub struct RegisterUserRequest {
    #[validate(email, length(max = 254))]
    pub email: String,
    #[validate(length(min = 8, max = 128))]
    pub password: String,
}

#[derive(Debug, Deserialize, Validate)]
pub struct LoginRequest {
    #[validate(email)]
    pub email: String,
    #[validate(length(min = 1))]
    pub password: String,
}

#[derive(Debug, Deserialize, Validate)]
pub struct RefreshTokenRequest {
    #[validate(length(min = 1))]
    pub refresh_token: String,
}

#[derive(Debug, Deserialize)]
pub struct LogoutRequest {
    pub refresh_token: String,
}

#[derive(Debug, Deserialize, Validate)]
pub struct ChangeUserRoleRequest {
    #[validate(length(min = 1))]
    pub role: String,
}

// ── Response DTOs ───────────────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct AuthTokensResponse {
    pub access_token: String,
    pub refresh_token: String,
    pub token_type: &'static str,
    pub expires_in: i64,
}

impl AuthTokensResponse {
    pub fn new(access_token: String, refresh_token: String, expires_in: i64) -> Self {
        Self {
            access_token,
            refresh_token,
            token_type: "Bearer",
            expires_in,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct RegisterUserResponse {
    pub user_id: Uuid,
    pub email: String,
    pub tokens: AuthTokensResponse,
}
