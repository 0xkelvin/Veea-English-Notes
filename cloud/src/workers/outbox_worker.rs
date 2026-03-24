use std::sync::Arc;
use std::time::Duration;

use tokio::sync::watch;
use tracing::{error, info};

use crate::infrastructure::messaging::event_bus::DynEventBus;
use crate::infrastructure::messaging::OutboxDispatcher;
use crate::infrastructure::persistence::postgres::PgOutboxRepository;

/// Background worker that polls the outbox table and publishes pending
/// domain events to the messaging system.
///
/// Runs on a configurable interval and respects graceful shutdown.
pub struct OutboxWorker {
    dispatcher: OutboxDispatcher<PgOutboxRepository>,
    poll_interval: Duration,
    shutdown_rx: watch::Receiver<bool>,
}

impl OutboxWorker {
    pub fn new(
        outbox_repo: PgOutboxRepository,
        event_bus: Arc<DynEventBus>,
        batch_size: i64,
        max_retries: i32,
        poll_interval: Duration,
        shutdown_rx: watch::Receiver<bool>,
    ) -> Self {
        let dispatcher = OutboxDispatcher::new(outbox_repo, event_bus, batch_size, max_retries);
        Self {
            dispatcher,
            poll_interval,
            shutdown_rx,
        }
    }

    /// Run the outbox polling loop until shutdown is signalled.
    pub async fn run(mut self) {
        info!(
            poll_interval_ms = self.poll_interval.as_millis() as u64,
            "Outbox worker started"
        );

        loop {
            tokio::select! {
                _ = self.shutdown_rx.changed() => {
                    info!("Outbox worker received shutdown signal");
                    break;
                }
                _ = tokio::time::sleep(self.poll_interval) => {
                    match self.dispatcher.dispatch_batch().await {
                        Ok(0) => { /* no pending events — idle */ }
                        Ok(count) => {
                            tracing::debug!(count, "Outbox batch dispatched");
                        }
                        Err(e) => {
                            error!(error = %e, "Outbox dispatch error");
                        }
                    }
                }
            }
        }

        info!("Outbox worker stopped");
    }
}
