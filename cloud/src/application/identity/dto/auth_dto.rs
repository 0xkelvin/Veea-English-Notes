use serde::{Deserialize, Serialize};
use uuid::Uuid;
use validator::Validate;

// ── Request DTOs ────────────────────────────────────────────────────

#[derive(Debug, Deserialize, Validate)]
pub struct RegisterUserRequest {
    /// An email address or a phone number. Format is checked by the
    /// `Identifier` value object, which reports a phone error for phone-shaped
    /// input rather than a misleading "invalid email".
    #[validate(length(min = 1, max = 254))]
    pub identifier: String,
    #[validate(length(min = 8, max = 128))]
    pub password: String,
}

#[derive(Debug, Deserialize, Validate)]
pub struct LoginRequest {
    /// An email address or a phone number.
    #[validate(length(min = 1, max = 254))]
    pub identifier: String,
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
    /// The normalised identifier the account was created with.
    pub identifier: String,
    pub tokens: AuthTokensResponse,
}

/// Body for `DELETE /users/me`.
///
/// The password is re-entered because the action is irreversible and an
/// access token alone is a weaker signal than knowing the password.
#[derive(Debug, Deserialize, Validate)]
pub struct DeleteAccountRequest {
    #[validate(length(min = 1))]
    pub password: String,
}

/// Body for `PUT /users/me/password`.
#[derive(Debug, Deserialize, Validate)]
pub struct ChangePasswordRequest {
    #[validate(length(min = 1))]
    pub current_password: String,
    #[validate(length(min = 8, max = 128))]
    pub new_password: String,
}

/// Body for `PUT /users/me/identifier`.
#[derive(Debug, Deserialize, Validate)]
pub struct ChangeIdentifierRequest {
    #[validate(length(min = 1, max = 254))]
    pub identifier: String,
    #[validate(length(min = 1))]
    pub password: String,
}
