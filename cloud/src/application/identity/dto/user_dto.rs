use chrono::{DateTime, Utc};
use serde::Serialize;
use uuid::Uuid;

use crate::domain::identity::entities::user::User;

/// Read-only projection of a User for API responses.
///
/// Intentionally omits sensitive fields (password_hash).
#[derive(Debug, Clone, Serialize)]
pub struct UserProfileResponse {
    pub id: Uuid,
    /// Absent on an account identified only by phone.
    pub email: Option<String>,
    /// Absent on an account identified only by email.
    pub phone: Option<String>,
    pub role: String,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl From<&User> for UserProfileResponse {
    fn from(user: &User) -> Self {
        Self {
            id: user.id,
            email: user.email.as_ref().map(|e| e.as_str().to_string()),
            phone: user.phone.as_ref().map(|p| p.as_str().to_string()),
            role: user.role.as_str().to_string(),
            status: user.status.as_str().to_string(),
            created_at: user.created_at,
            updated_at: user.updated_at,
        }
    }
}

impl From<User> for UserProfileResponse {
    fn from(user: User) -> Self {
        Self::from(&user)
    }
}

/// Summary DTO for list endpoints.
#[derive(Debug, Clone, Serialize)]
pub struct UserSummary {
    pub id: Uuid,
    /// Whichever identifier the account is primarily known by.
    pub identifier: String,
    pub role: String,
    pub status: String,
    pub created_at: DateTime<Utc>,
}

impl From<&User> for UserSummary {
    fn from(user: &User) -> Self {
        Self {
            id: user.id,
            identifier: user.primary_identifier(),
            role: user.role.as_str().to_string(),
            status: user.status.as_str().to_string(),
            created_at: user.created_at,
        }
    }
}
