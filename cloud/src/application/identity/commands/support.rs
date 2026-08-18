//! Helpers shared by the identity commands.
//!
//! Outbox wrapping and refresh-token generation were previously copied into
//! each command file. Sharing them keeps the token format in one place, which
//! matters because the hash here has to match the one the lookup uses.

use base64::Engine;
use chrono::{DateTime, Utc};
use sha2::Digest;

use crate::application::identity::ports::id_generator::IdGenerator;
use crate::domain::identity::events::IdentityDomainEvent;
use crate::domain::identity::repositories::outbox_repository::{OutboxEvent, OutboxStatus};

/// Wraps a domain event for the transactional outbox.
pub fn build_outbox_event(
    event: &IdentityDomainEvent,
    id_gen: &impl IdGenerator,
    now: DateTime<Utc>,
) -> Result<OutboxEvent, anyhow::Error> {
    Ok(OutboxEvent {
        id: id_gen.new_id(),
        aggregate_type: event.aggregate_type().to_string(),
        aggregate_id: event.aggregate_id(),
        event_type: event.event_type().to_string(),
        payload: serde_json::to_value(event)?,
        metadata: serde_json::json!({}),
        status: OutboxStatus::Pending,
        occurred_at: now,
        published_at: None,
        retry_count: 0,
    })
}

/// A fresh opaque refresh token: 256 bits of randomness, URL-safe.
pub fn generate_refresh_token() -> String {
    let mut bytes = [0u8; 32];
    rand::fill(&mut bytes);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// Hashes a refresh token for storage.
///
/// Only the hash is persisted, so a database leak does not hand over usable
/// sessions. SHA-256 is sufficient here — unlike a password, the token is
/// already high-entropy and not brute-forceable.
pub fn hash_refresh_token(token: &str) -> String {
    hex::encode(sha2::Sha256::digest(token.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_tokens_differ() {
        assert_ne!(generate_refresh_token(), generate_refresh_token());
    }

    #[test]
    fn hashing_is_stable_and_hides_the_token() {
        let token = generate_refresh_token();
        let hash = hash_refresh_token(&token);

        assert_eq!(hash, hash_refresh_token(&token));
        assert!(!hash.contains(&token));
        assert_eq!(hash.len(), 64); // SHA-256 as hex
    }
}
