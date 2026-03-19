//! Kafka event bus — only compiled when the `kafka` feature is active.

#[cfg(feature = "kafka")]
mod inner {
    use chrono::Utc;
    use rdkafka::producer::{FutureProducer, FutureRecord};
    use std::time::Duration;

    use crate::domain::identity::repositories::outbox_repository::OutboxEvent;
    use crate::infrastructure::messaging::message_envelope::MessageEnvelope;
    use crate::infrastructure::messaging::topics::topic_for_event;

    pub struct KafkaEventBus {
        producer: FutureProducer,
    }

    impl KafkaEventBus {
        pub fn new(producer: FutureProducer) -> Self {
            Self { producer }
        }

        pub async fn publish(&self, event: &OutboxEvent) -> Result<(), anyhow::Error> {
            let topic = topic_for_event(&event.aggregate_type, &event.event_type);
            let envelope = MessageEnvelope::from_outbox(event, Utc::now());
            let data = envelope.to_json_bytes()?;
            let key = event.aggregate_id.to_string();

            let record = FutureRecord::to(&topic)
                .key(&key)
                .payload(&data);

            self.producer
                .send(record, Duration::from_secs(5))
                .await
                .map_err(|(e, _)| anyhow::anyhow!("Kafka produce failed: {e}"))?;

            Ok(())
        }
    }
}

#[cfg(feature = "kafka")]
pub use inner::KafkaEventBus;
