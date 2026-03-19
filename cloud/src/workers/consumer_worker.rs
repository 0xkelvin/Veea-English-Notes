use std::sync::Arc;

use futures_util::StreamExt;
use tokio::sync::watch;
use tracing::{error, info, warn};

use crate::bootstrap::messaging::MessagingConnection;
use crate::infrastructure::messaging::consumer_runtime::{IdempotentConsumer, MessageHandler};
use crate::infrastructure::persistence::postgres::PgInboxRepository;

/// Background NATS consumer worker.
///
/// Subscribes to a subject and routes messages through `IdempotentConsumer`
/// for exactly-once processing guarantees.
pub struct ConsumerWorker<H: MessageHandler> {
    consumer: IdempotentConsumer<H, PgInboxRepository>,
    subject: String,
    messaging: Arc<MessagingConnection>,
    shutdown_rx: watch::Receiver<bool>,
}

impl<H: MessageHandler + 'static> ConsumerWorker<H> {
    pub fn new(
        handler: H,
        inbox: Arc<PgInboxRepository>,
        subject: String,
        messaging: Arc<MessagingConnection>,
        shutdown_rx: watch::Receiver<bool>,
    ) -> Self {
        let consumer = IdempotentConsumer::new(handler, inbox);
        Self {
            consumer,
            subject,
            messaging,
            shutdown_rx,
        }
    }

    /// Run the consumer loop until shutdown is signalled.
    pub async fn run(mut self) {
        let client = match self.messaging.as_ref() {
            MessagingConnection::Nats(client) => client.clone(),
            #[cfg(feature = "kafka")]
            MessagingConnection::Kafka(_) => {
                warn!("Kafka consumer not yet implemented in consumer_worker");
                return;
            }
            _ => {
                warn!("Messaging is disabled; consumer worker will not start");
                return;
            }
        };

        let mut subscriber = match client.subscribe(self.subject.clone()).await {
            Ok(sub) => sub,
            Err(e) => {
                error!(error = %e, subject = %self.subject, "Failed to subscribe");
                return;
            }
        };

        info!(subject = %self.subject, "Consumer worker started");

        loop {
            tokio::select! {
                _ = self.shutdown_rx.changed() => {
                    info!(subject = %self.subject, "Consumer worker received shutdown signal");
                    break;
                }
                msg = subscriber.next() => {
                    match msg {
                        Some(message) => {
                            // Use NATS message headers for message-id if available,
                            // otherwise derive from payload hash
                            let message_id = message
                                .headers
                                .as_ref()
                                .and_then(|h: &async_nats::HeaderMap| h.get("message-id"))
                                .map(|v: &async_nats::HeaderValue| v.to_string())
                                .unwrap_or_else(|| {
                                    use sha2::Digest;
                                    let hash = sha2::Sha256::digest(&message.payload);
                                    hex::encode(hash)
                                });

                            if let Err(e) = self.consumer.process(&message_id, &message.payload).await {
                                error!(
                                    error = %e,
                                    message_id = %message_id,
                                    subject = %self.subject,
                                    "Failed to process message"
                                );
                            }
                        }
                        None => {
                            warn!(subject = %self.subject, "NATS subscription closed");
                            break;
                        }
                    }
                }
            }
        }

        info!(subject = %self.subject, "Consumer worker stopped");
    }
}

/// A no-op message handler for demonstration / logging purposes.
///
/// Replace with domain-specific handlers in production.
pub struct LoggingHandler;

impl MessageHandler for LoggingHandler {
    async fn handle(&self, payload: &[u8]) -> Result<(), anyhow::Error> {
        let text = String::from_utf8_lossy(payload);
        info!(payload_len = payload.len(), "Received message: {text}");
        Ok(())
    }

    fn consumer_name(&self) -> &str {
        "logging-handler"
    }
}
