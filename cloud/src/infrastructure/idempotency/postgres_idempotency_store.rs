use sqlx::PgPool;

use crate::common::idempotency::IdempotencyRecord;

/// Postgres-backed idempotency store for replay protection on write endpoints.
pub struct PgIdempotencyStore {
    pool: PgPool,
}

impl PgIdempotencyStore {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Look up a previously saved idempotent response.
    pub async fn get(
        &self,
        idempotency_key: &str,
    ) -> Result<Option<IdempotencyRecord>, anyhow::Error> {
        let row = sqlx::query_as::<_, IdempotencyRow>(
            "SELECT id, idempotency_key, request_hash, response_status,
                    response_body, created_at
             FROM idempotency_records
             WHERE idempotency_key = $1",
        )
        .bind(idempotency_key)
        .fetch_optional(&self.pool)
        .await?;

        Ok(row.map(Into::into))
    }

    /// Save an idempotent response for future replay.
    pub async fn save(&self, record: &IdempotencyRecord) -> Result<(), anyhow::Error> {
        sqlx::query(
            "INSERT INTO idempotency_records
                (id, idempotency_key, request_hash, response_status, response_body, created_at)
             VALUES ($1, $2, $3, $4, $5, $6)
             ON CONFLICT (idempotency_key) DO NOTHING",
        )
        .bind(record.id)
        .bind(&record.idempotency_key)
        .bind(&record.request_hash)
        .bind(record.response_status)
        .bind(&record.response_body)
        .bind(record.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}

#[derive(Debug, sqlx::FromRow)]
struct IdempotencyRow {
    id: uuid::Uuid,
    idempotency_key: String,
    request_hash: String,
    response_status: i32,
    response_body: serde_json::Value,
    created_at: chrono::DateTime<chrono::Utc>,
}

impl From<IdempotencyRow> for IdempotencyRecord {
    fn from(row: IdempotencyRow) -> Self {
        Self {
            id: row.id,
            idempotency_key: row.idempotency_key,
            request_hash: row.request_hash,
            response_status: row.response_status,
            response_body: row.response_body,
            created_at: row.created_at,
        }
    }
}
