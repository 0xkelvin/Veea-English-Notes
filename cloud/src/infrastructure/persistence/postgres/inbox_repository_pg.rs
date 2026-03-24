use sqlx::PgPool;

use crate::domain::identity::repositories::inbox_repository::{InboxRecord, InboxRepository};

pub struct PgInboxRepository {
    pool: PgPool,
}

impl PgInboxRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

impl InboxRepository for PgInboxRepository {
    async fn exists(
        &self,
        message_id: &str,
        consumer_name: &str,
    ) -> Result<bool, anyhow::Error> {
        let row: (bool,) = sqlx::query_as(
            "SELECT EXISTS(
                SELECT 1 FROM inbox_messages
                WHERE message_id = $1 AND consumer_name = $2
            )",
        )
        .bind(message_id)
        .bind(consumer_name)
        .fetch_one(&self.pool)
        .await?;
        Ok(row.0)
    }

    async fn insert(&self, record: &InboxRecord) -> Result<(), anyhow::Error> {
        sqlx::query(
            "INSERT INTO inbox_messages (message_id, consumer_name, processed_at)
             VALUES ($1, $2, $3)
             ON CONFLICT (message_id, consumer_name) DO NOTHING",
        )
        .bind(&record.message_id)
        .bind(&record.consumer_name)
        .bind(record.processed_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}
