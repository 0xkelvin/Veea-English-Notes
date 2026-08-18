use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Raised when a new user account is created.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserRegistered {
    pub user_id: Uuid,
    /// The email address or phone number the account was created with.
    pub identifier: String,
    /// `"email"` or `"phone"`, so consumers can route a welcome message
    /// without re-parsing the identifier.
    pub identifier_kind: String,
    pub role: String,
    pub occurred_at: DateTime<Utc>,
}
