use async_nats::Client;
use chrono::Utc;

use crate::domain::identity::repositories::outbox_repository::OutboxEvent;

use super::message_envelope::MessageEnvelope;
use super::topics::topic_for_event;

/// NATS JetStream event bus implementation.
pub struct NatsEventBus {
    client: Client,
}

impl NatsEventBus {
    pub fn new(client: Client) -> Self {
        Self { client }
    }

    pub async fn publish(&self, event: &OutboxEvent) -> Result<(), anyhow::Error> {
        let subject = topic_for_event(&event.aggregate_type, &event.event_type);
        let envelope = MessageEnvelope::from_outbox(event, Utc::now());
        let data = envelope.to_json_bytes()?;

        self.client
            .publish(subject, data.into())
            .await
            .map_err(|e| anyhow::anyhow!("NATS publish failed: {e}"))?;

        Ok(())
    }
}
