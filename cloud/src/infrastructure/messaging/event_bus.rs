use std::sync::Arc;

use crate::bootstrap::messaging::MessagingConnection;
use crate::domain::identity::repositories::outbox_repository::OutboxEvent;

use super::nats_bus::NatsEventBus;

/// Enum-based event bus that dispatches to the active messaging backend.
///
/// We use an enum instead of `dyn EventBus` because the `EventBus` trait
/// uses `impl Future` in return position, which is not dyn-compatible.
pub enum DynEventBus {
    Nats(NatsEventBus),
    #[cfg(feature = "kafka")]
    Kafka(super::kafka_bus::KafkaEventBus),
    NoOp,
}

impl DynEventBus {
    /// Publish an outbox event to the configured messaging backend.
    pub async fn publish(&self, event: &OutboxEvent) -> Result<(), anyhow::Error> {
        match self {
            DynEventBus::Nats(bus) => bus.publish(event).await,
            #[cfg(feature = "kafka")]
            DynEventBus::Kafka(bus) => bus.publish(event).await,
            DynEventBus::NoOp => {
                tracing::debug!("NoOpEventBus: event discarded (messaging disabled)");
                Ok(())
            }
        }
    }
}

/// Create the appropriate event bus based on the active messaging connection.
pub fn create_event_bus(conn: &Arc<MessagingConnection>) -> DynEventBus {
    match conn.as_ref() {
        MessagingConnection::Nats(client) => {
            DynEventBus::Nats(NatsEventBus::new(client.clone()))
        }
        #[cfg(feature = "kafka")]
        MessagingConnection::Kafka(kafka) => {
            DynEventBus::Kafka(super::kafka_bus::KafkaEventBus::new(kafka.producer.clone()))
        }
        #[allow(unreachable_patterns)]
        _ => {
            tracing::warn!("No messaging backend available; using no-op event bus");
            DynEventBus::NoOp
        }
    }
}
