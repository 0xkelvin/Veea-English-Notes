use std::future::Future;

use crate::domain::identity::repositories::outbox_repository::OutboxEvent;

/// Port for publishing domain events to external messaging systems.
///
/// Implementations adapt to NATS, Kafka, or other brokers.
/// The outbox worker calls `publish` after reading pending events.
pub trait EventBus: Send + Sync {
    /// Publish an outbox event to the messaging system.
    fn publish(&self, event: &OutboxEvent) -> impl Future<Output = Result<(), anyhow::Error>> + Send;
}
