use chrono::{DateTime, Utc};
use uuid::Uuid;

/// Claims embedded in an access token JWT.
#[derive(Debug, Clone)]
pub struct AccessTokenClaims {
    pub sub: Uuid,
    pub email: String,
    pub role: String,
    pub jti: Uuid,
    pub iat: DateTime<Utc>,
    pub exp: DateTime<Utc>,
}

/// Decoded/validated token claims returned after verification.
#[derive(Debug, Clone)]
pub struct ValidatedClaims {
    pub sub: Uuid,
    pub email: String,
    pub role: String,
    pub jti: Uuid,
    pub exp: DateTime<Utc>,
}

/// Port for JWT token creation and validation.
pub trait JwtService: Send + Sync {
    /// Create a signed access token from claims.
    fn create_access_token(
        &self,
        claims: &AccessTokenClaims,
    ) -> Result<String, anyhow::Error>;

    /// Validate and decode an access token.
    fn validate_access_token(
        &self,
        token: &str,
    ) -> Result<ValidatedClaims, anyhow::Error>;
}
