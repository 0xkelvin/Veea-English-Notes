use tracing::info;

use super::config::{MessagingBackend, MessagingConfig};

/// Messaging connection handle — holds the underlying client for the selected backend.
pub enum MessagingConnection {
    Nats(async_nats::Client),
    #[cfg(feature = "kafka")]
    Kafka(KafkaConnection),
    /// Fallback when Kafka feature is not compiled in but configured.
    Disabled,
}

#[cfg(feature = "kafka")]
pub struct KafkaConnection {
    pub producer: rdkafka::producer::FutureProducer,
    pub consumer_config: rdkafka::ClientConfig,
}

/// Initialize the messaging connection based on configuration.
pub async fn init_messaging(config: &MessagingConfig) -> Result<MessagingConnection, anyhow::Error> {
    match config.backend {
        MessagingBackend::Nats => {
            let client = async_nats::connect(&config.nats_url).await?;
            info!(url = %config.nats_url, "NATS connection established");
            Ok(MessagingConnection::Nats(client))
        }
        MessagingBackend::Kafka => {
            #[cfg(feature = "kafka")]
            {
                use rdkafka::config::ClientConfig;
                use rdkafka::producer::FutureProducer;

                let producer: FutureProducer = ClientConfig::new()
                    .set("bootstrap.servers", &config.kafka_brokers)
                    .set("client.id", &config.kafka_client_id)
                    .set("message.timeout.ms", "5000")
                    .set("acks", "all")
                    .create()?;

                let mut consumer_config = ClientConfig::new();
                consumer_config
                    .set("bootstrap.servers", &config.kafka_brokers)
                    .set("group.id", &config.kafka_group_id)
                    .set("client.id", &config.kafka_client_id)
                    .set("auto.offset.reset", "earliest")
                    .set("enable.auto.commit", "false");

                info!(brokers = %config.kafka_brokers, "Kafka connection established");
                Ok(MessagingConnection::Kafka(KafkaConnection {
                    producer,
                    consumer_config,
                }))
            }
            #[cfg(not(feature = "kafka"))]
            {
                tracing::warn!(
                    "Kafka backend selected but 'kafka' feature is not enabled. \
                     Messaging is disabled."
                );
                Ok(MessagingConnection::Disabled)
            }
        }
    }
}
