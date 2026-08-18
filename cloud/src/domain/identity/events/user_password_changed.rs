use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Raised when a user changes their own password.
///
/// Carries no credential material of any kind — this event reaches the
/// message bus, and a hash there would be a durable copy of something that
/// should only ever live in the users table.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserPasswordChanged {
    pub user_id: Uuid,
    pub occurred_at: DateTime<Utc>,
}
