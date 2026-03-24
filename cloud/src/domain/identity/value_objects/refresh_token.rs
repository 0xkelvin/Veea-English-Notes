use chrono::{DateTime, Utc};
use uuid::Uuid;

/// A refresh token record tied to a user session.
///
/// The actual token value is never stored in plaintext — only its hash.
/// The `value` field here is transient and used only when issuing a new token
/// to send back to the client.
#[derive(Debug, Clone)]
pub struct RefreshToken {
    pub id: Uuid,
    pub user_id: Uuid,
    pub token_hash: String,
    pub expires_at: DateTime<Utc>,
    pub revoked_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

impl RefreshToken {
    /// Create a new refresh token record.
    pub fn new(
        id: Uuid,
        user_id: Uuid,
        token_hash: String,
        expires_at: DateTime<Utc>,
        created_at: DateTime<Utc>,
    ) -> Self {
        Self {
            id,
            user_id,
            token_hash,
            expires_at,
            revoked_at: None,
            created_at,
        }
    }

    /// Check whether this token has been revoked.
    pub fn is_revoked(&self) -> bool {
        self.revoked_at.is_some()
    }

    /// Check whether this token has expired.
    pub fn is_expired(&self, now: DateTime<Utc>) -> bool {
        self.expires_at <= now
    }

    /// Check if the token is still usable (not revoked and not expired).
    pub fn is_valid(&self, now: DateTime<Utc>) -> bool {
        !self.is_revoked() && !self.is_expired(now)
    }

    /// Revoke this token.
    pub fn revoke(&mut self, now: DateTime<Utc>) {
        self.revoked_at = Some(now);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    fn make_token(expires_in: Duration) -> RefreshToken {
        let now = Utc::now();
        RefreshToken::new(
            Uuid::new_v4(),
            Uuid::new_v4(),
            "hashed_token".to_string(),
            now + expires_in,
            now,
        )
    }

    #[test]
    fn new_token_is_valid() {
        let token = make_token(Duration::hours(1));
        assert!(token.is_valid(Utc::now()));
    }

    #[test]
    fn expired_token_is_invalid() {
        let token = make_token(Duration::seconds(-1));
        assert!(!token.is_valid(Utc::now()));
    }

    #[test]
    fn revoked_token_is_invalid() {
        let mut token = make_token(Duration::hours(1));
        token.revoke(Utc::now());
        assert!(!token.is_valid(Utc::now()));
        assert!(token.is_revoked());
    }
}
