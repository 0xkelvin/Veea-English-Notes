use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::application::identity::transaction::PgTransaction;
use crate::domain::identity::repositories::outbox_repository::{OutboxEvent, OutboxRepository};

use super::models::OutboxEventRow;

pub struct PgOutboxRepository {
    pool: PgPool,
}

impl PgOutboxRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

impl OutboxRepository for PgOutboxRepository {
    async fn insert(&self, event: &OutboxEvent) -> Result<(), anyhow::Error> {
        sqlx::query(
            "INSERT INTO outbox_events
                (id, aggregate_type, aggregate_id, event_type, payload, metadata,
                 status, occurred_at, published_at, retry_count)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        )
        .bind(event.id)
        .bind(&event.aggregate_type)
        .bind(event.aggregate_id)
        .bind(&event.event_type)
        .bind(&event.payload)
        .bind(&event.metadata)
        .bind(event.status.as_str())
        .bind(event.occurred_at)
        .bind(event.published_at)
        .bind(event.retry_count)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn fetch_pending(&self, batch_size: i64) -> Result<Vec<OutboxEvent>, anyhow::Error> {
        let rows = sqlx::query_as::<_, OutboxEventRow>(
            "SELECT id, aggregate_type, aggregate_id, event_type, payload, metadata,
                    status, occurred_at, published_at, retry_count
             FROM outbox_events
             WHERE status = 'pending'
             ORDER BY occurred_at ASC
             LIMIT $1
             FOR UPDATE SKIP LOCKED",
        )
        .bind(batch_size)
        .fetch_all(&self.pool)
        .await?;

        Ok(rows.into_iter().map(OutboxEvent::from).collect())
    }

    async fn mark_published(
        &self,
        id: Uuid,
        published_at: DateTime<Utc>,
    ) -> Result<(), anyhow::Error> {
        sqlx::query(
            "UPDATE outbox_events SET status = 'published', published_at = $1 WHERE id = $2",
        )
        .bind(published_at)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn mark_failed(&self, id: Uuid, max_retries: i32) -> Result<(), anyhow::Error> {
        sqlx::query(
            "UPDATE outbox_events
             SET retry_count = retry_count + 1,
                 status = CASE WHEN retry_count + 1 >= $1 THEN 'failed' ELSE 'pending' END
             WHERE id = $2",
        )
        .bind(max_retries)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}

// ── Transactional variant ──────────────────────────────────────────────────────

use crate::application::identity::transaction::TransactionalOutboxRepository;

impl TransactionalOutboxRepository for PgOutboxRepository {
    async fn insert_tx<'a>(
        &self,
        tx: &mut PgTransaction<'a>,
        event: &OutboxEvent,
    ) -> Result<(), anyhow::Error> {
        sqlx::query(
            "INSERT INTO outbox_events
                (id, aggregate_type, aggregate_id, event_type, payload, metadata,
                 status, occurred_at, published_at, retry_count)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        )
        .bind(event.id)
        .bind(&event.aggregate_type)
        .bind(event.aggregate_id)
        .bind(&event.event_type)
        .bind(&event.payload)
        .bind(&event.metadata)
        .bind(event.status.as_str())
        .bind(event.occurred_at)
        .bind(event.published_at)
        .bind(event.retry_count)
        .execute(&mut **tx)
        .await?;
        Ok(())
    }
}
