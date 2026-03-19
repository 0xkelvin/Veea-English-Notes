use std::sync::Arc;

use chrono::Utc;
use tracing::{error, info, instrument};

use crate::domain::identity::repositories::outbox_repository::OutboxRepository;

use super::event_bus::DynEventBus;

/// Polls the outbox table and publishes pending events to the event bus.
///
/// Called periodically by the outbox worker.
pub struct OutboxDispatcher<R: OutboxRepository> {
    outbox_repo: R,
    event_bus: Arc<DynEventBus>,
    batch_size: i64,
    max_retries: i32,
}

impl<R: OutboxRepository> OutboxDispatcher<R> {
    pub fn new(
        outbox_repo: R,
        event_bus: Arc<DynEventBus>,
        batch_size: i64,
        max_retries: i32,
    ) -> Self {
        Self {
            outbox_repo,
            event_bus,
            batch_size,
            max_retries,
        }
    }

    /// Process one batch of pending outbox events.
    ///
    /// Returns the number of events successfully published.
    #[instrument(skip_all, fields(batch_size = self.batch_size))]
    pub async fn dispatch_batch(&self) -> Result<usize, anyhow::Error> {
        let events = self.outbox_repo.fetch_pending(self.batch_size).await?;
        if events.is_empty() {
            return Ok(0);
        }

        let mut published = 0;

        for event in &events {
            match self.event_bus.publish(event).await {
                Ok(()) => {
                    self.outbox_repo
                        .mark_published(event.id, Utc::now())
                        .await?;
                    published += 1;
                }
                Err(e) => {
                    error!(
                        event_id = %event.id,
                        event_type = %event.event_type,
                        error = %e,
                        "Failed to publish outbox event"
                    );
                    self.outbox_repo
                        .mark_failed(event.id, self.max_retries)
                        .await?;
                }
            }
        }

        if published > 0 {
            info!(count = published, "Published outbox events");
        }

        Ok(published)
    }
}
