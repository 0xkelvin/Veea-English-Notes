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
    pub email: String,
    pub role: String,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl From<&User> for UserProfileResponse {
    fn from(user: &User) -> Self {
        Self {
            id: user.id,
            email: user.email.as_str().to_string(),
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
    pub email: String,
    pub role: String,
    pub status: String,
    pub created_at: DateTime<Utc>,
}

impl From<&User> for UserSummary {
    fn from(user: &User) -> Self {
        Self {
            id: user.id,
            email: user.email.as_str().to_string(),
            role: user.role.as_str().to_string(),
            status: user.status.as_str().to_string(),
            created_at: user.created_at,
        }
    }
}
