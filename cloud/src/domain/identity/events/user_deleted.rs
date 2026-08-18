use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Raised when a user deletes their own account.
///
/// The row is gone by the time consumers see this, so the identifier is
/// carried in the payload — there is nothing left to look it up from.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserDeleted {
    pub user_id: Uuid,
    pub identifier: String,
    pub occurred_at: DateTime<Utc>,
}
