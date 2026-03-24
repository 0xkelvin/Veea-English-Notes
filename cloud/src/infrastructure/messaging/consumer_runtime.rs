use std::sync::Arc;

use tracing::{error, info, instrument};

use crate::domain::identity::repositories::inbox_repository::{InboxRecord, InboxRepository};

/// Message handler trait implemented by domain-specific consumers.
pub trait MessageHandler: Send + Sync {
    /// Process a single message payload.
    fn handle(
        &self,
        payload: &[u8],
    ) -> impl std::future::Future<Output = Result<(), anyhow::Error>> + Send;

    /// The consumer name used for inbox deduplication.
    fn consumer_name(&self) -> &str;
}

/// Generic consumer runtime that wraps any `MessageHandler` with idempotency.
///
/// Before processing, it checks the inbox table. After processing, it records
/// the message to prevent duplicate handling.
pub struct IdempotentConsumer<H: MessageHandler, I: InboxRepository> {
    handler: H,
    inbox: Arc<I>,
}

impl<H: MessageHandler, I: InboxRepository> IdempotentConsumer<H, I> {
    pub fn new(handler: H, inbox: Arc<I>) -> Self {
        Self { handler, inbox }
    }

    /// Process a message with idempotency guarantees.
    #[instrument(skip_all, fields(message_id = %message_id, consumer = %self.handler.consumer_name()))]
    pub async fn process(&self, message_id: &str, payload: &[u8]) -> Result<(), anyhow::Error> {
        let consumer_name = self.handler.consumer_name();

        // Check inbox for duplicate
        if self.inbox.exists(message_id, consumer_name).await? {
            info!("Message already processed, skipping");
            return Ok(());
        }

        // Process
        if let Err(e) = self.handler.handle(payload).await {
            error!(error = %e, "Message handler failed");
            return Err(e);
        }

        // Record in inbox
        let record = InboxRecord {
            message_id: message_id.to_string(),
            consumer_name: consumer_name.to_string(),
            processed_at: chrono::Utc::now(),
        };
        self.inbox.insert(&record).await?;

        Ok(())
    }
}
