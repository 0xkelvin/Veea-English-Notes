use std::future::Future;

use uuid::Uuid;

use crate::domain::identity::value_objects::refresh_token::RefreshToken;

/// Port for refresh token persistence.
pub trait RefreshTokenRepository: Send + Sync {
    /// Store a new refresh token.
    fn insert(&self, token: &RefreshToken) -> impl Future<Output = Result<(), anyhow::Error>> + Send;

    /// Find a refresh token by its hash.
    fn find_by_token_hash(
        &self,
        token_hash: &str,
    ) -> impl Future<Output = Result<Option<RefreshToken>, anyhow::Error>> + Send;

    /// Mark a refresh token as revoked.
    fn revoke(
        &self,
        id: Uuid,
        revoked_at: chrono::DateTime<chrono::Utc>,
    ) -> impl Future<Output = Result<(), anyhow::Error>> + Send;

    /// Revoke all refresh tokens for a user (e.g. on password change).
    fn revoke_all_for_user(
        &self,
        user_id: Uuid,
        revoked_at: chrono::DateTime<chrono::Utc>,
    ) -> impl Future<Output = Result<u64, anyhow::Error>> + Send;
}
