use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::domain::identity::repositories::outbox_repository::OutboxEvent;

/// Standard message envelope wrapping every outbound event.
///
/// Consumers use the envelope metadata for deduplication, ordering, and routing.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageEnvelope {
    pub message_id: Uuid,
    pub aggregate_type: String,
    pub aggregate_id: Uuid,
    pub event_type: String,
    pub payload: serde_json::Value,
    pub metadata: serde_json::Value,
    pub occurred_at: DateTime<Utc>,
    pub published_at: DateTime<Utc>,
}

impl MessageEnvelope {
    /// Build an envelope from an outbox event.
    pub fn from_outbox(event: &OutboxEvent, published_at: DateTime<Utc>) -> Self {
        Self {
            message_id: event.id,
            aggregate_type: event.aggregate_type.clone(),
            aggregate_id: event.aggregate_id,
            event_type: event.event_type.clone(),
            payload: event.payload.clone(),
            metadata: event.metadata.clone(),
            occurred_at: event.occurred_at,
            published_at,
        }
    }

    /// Serialize the envelope to JSON bytes for publishing.
    pub fn to_json_bytes(&self) -> Result<Vec<u8>, anyhow::Error> {
        Ok(serde_json::to_vec(self)?)
    }
}
