use tracing::instrument;

use crate::application::identity::ports::clock::Clock;
use crate::common::result::AppResult;
use crate::domain::identity::repositories::refresh_token_repository::RefreshTokenRepository;

#[derive(Debug)]
pub struct RevokeRefreshTokenCommand {
    pub refresh_token: String,
}

/// Revoke (logout) a refresh token.
///
/// Finds the token by hash and marks it as revoked.
/// If the token doesn't exist or is already revoked, returns success (idempotent).
#[instrument(skip_all)]
pub async fn handle<R, C>(
    cmd: RevokeRefreshTokenCommand,
    refresh_repo: &R,
    clock: &C,
) -> AppResult<()>
where
    R: RefreshTokenRepository,
    C: Clock,
{
    let token_hash = hash_refresh_token(&cmd.refresh_token);
    let existing = refresh_repo.find_by_token_hash(&token_hash).await?;

    if let Some(token) = existing
        && !token.is_revoked()
    {
        let now = clock.now();
        refresh_repo.revoke(token.id, now).await?;
    }
    // Idempotent: if token not found, still return Ok
    Ok(())
}

fn hash_refresh_token(token: &str) -> String {
    use sha2::Digest;
    let hash = sha2::Sha256::digest(token.as_bytes());
    hex::encode(hash)
}
