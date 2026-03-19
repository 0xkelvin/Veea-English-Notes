use uuid::Uuid;

/// Represents an idempotency key sent by the client to prevent duplicate writes.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct IdempotencyKey(String);

impl IdempotencyKey {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Stored idempotency record for replaying previous responses.
#[derive(Debug, Clone)]
pub struct IdempotencyRecord {
    pub id: Uuid,
    pub idempotency_key: String,
    pub request_hash: String,
    pub response_status: i32,
    pub response_body: serde_json::Value,
    pub created_at: chrono::DateTime<chrono::Utc>,
}
