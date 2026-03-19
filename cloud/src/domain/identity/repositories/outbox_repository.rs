use std::future::Future;

use chrono::{DateTime, Utc};
use uuid::Uuid;

/// A pending outbox event record.
#[derive(Debug, Clone)]
pub struct OutboxEvent {
    pub id: Uuid,
    pub aggregate_type: String,
    pub aggregate_id: Uuid,
    pub event_type: String,
    pub payload: serde_json::Value,
    pub metadata: serde_json::Value,
    pub status: OutboxStatus,
    pub occurred_at: DateTime<Utc>,
    pub published_at: Option<DateTime<Utc>>,
    pub retry_count: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutboxStatus {
    Pending,
    Published,
    Failed,
}

impl OutboxStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            OutboxStatus::Pending => "pending",
            OutboxStatus::Published => "published",
            OutboxStatus::Failed => "failed",
        }
    }

    pub fn from_str_checked(s: &str) -> Self {
        match s {
            "published" => OutboxStatus::Published,
            "failed" => OutboxStatus::Failed,
            _ => OutboxStatus::Pending,
        }
    }
}

/// Port for outbox event persistence.
///
/// Events are written within the same transaction as aggregate mutations,
/// then polled and published by the outbox worker.
pub trait OutboxRepository: Send + Sync {
    /// Insert an outbox event (within a transaction).
    fn insert(&self, event: &OutboxEvent) -> impl Future<Output = Result<(), anyhow::Error>> + Send;

    /// Fetch a batch of unpublished events ordered by `occurred_at`.
    fn fetch_pending(
        &self,
        batch_size: i64,
    ) -> impl Future<Output = Result<Vec<OutboxEvent>, anyhow::Error>> + Send;

    /// Mark an event as published.
    fn mark_published(
        &self,
        id: Uuid,
        published_at: DateTime<Utc>,
    ) -> impl Future<Output = Result<(), anyhow::Error>> + Send;

    /// Increment retry count and optionally mark as failed.
    fn mark_failed(
        &self,
        id: Uuid,
        max_retries: i32,
    ) -> impl Future<Output = Result<(), anyhow::Error>> + Send;
}
