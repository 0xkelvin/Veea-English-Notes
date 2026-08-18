use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Raised when a user changes the email address or phone number on their
/// account.
///
/// Both the old and new values are carried so a consumer can notify the
/// previous address that the change happened — the usual defence against a
/// hijacked session quietly moving an account somewhere else.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserIdentifierChanged {
    pub user_id: Uuid,
    pub previous_identifier: String,
    pub new_identifier: String,
    /// `"email"` or `"phone"`.
    pub identifier_kind: String,
    pub occurred_at: DateTime<Utc>,
}
