use std::future::Future;

use chrono::{DateTime, Utc};

/// A record of a previously processed inbound message.
#[derive(Debug, Clone)]
pub struct InboxRecord {
    pub message_id: String,
    pub consumer_name: String,
    pub processed_at: DateTime<Utc>,
}

/// Port for inbox (idempotent consumer) persistence.
///
/// Before processing an incoming message, the consumer checks the inbox.
/// If the message has already been processed, it is skipped.
pub trait InboxRepository: Send + Sync {
    /// Check whether a message has already been processed by a given consumer.
    fn exists(
        &self,
        message_id: &str,
        consumer_name: &str,
    ) -> impl Future<Output = Result<bool, anyhow::Error>> + Send;

    /// Record that a message has been processed.
    fn insert(&self, record: &InboxRecord) -> impl Future<Output = Result<(), anyhow::Error>> + Send;
}
