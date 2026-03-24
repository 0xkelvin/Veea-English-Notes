use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Raised when a user's role is changed by an administrator.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserRoleChanged {
    pub user_id: Uuid,
    pub old_role: String,
    pub new_role: String,
    pub changed_by: Uuid,
    pub occurred_at: DateTime<Utc>,
}
