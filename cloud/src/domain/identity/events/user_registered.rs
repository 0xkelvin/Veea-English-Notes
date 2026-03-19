use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Raised when a new user account is created.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserRegistered {
    pub user_id: Uuid,
    pub email: String,
    pub role: String,
    pub occurred_at: DateTime<Utc>,
}
