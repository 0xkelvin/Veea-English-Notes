use chrono::{DateTime, Utc};
use sqlx::FromRow;
use uuid::Uuid;

use crate::domain::identity::entities::user::User;
use crate::domain::identity::value_objects::email::Email;
use crate::domain::identity::value_objects::password_hash::PasswordHash;
use crate::domain::identity::value_objects::refresh_token::RefreshToken;
use crate::domain::identity::value_objects::user_role::{UserRole, UserStatus};

// ── User row ───────────────────────────────────────────────────────────────────

#[derive(Debug, FromRow)]
pub struct UserRow {
    pub id: Uuid,
    pub email: String,
    pub password_hash: String,
    pub role: String,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl UserRow {
    pub fn into_domain(self) -> Result<User, anyhow::Error> {
        let email = Email::new(self.email)?;
        let password_hash = PasswordHash::new(self.password_hash)?;
        let role = UserRole::from_str_checked(&self.role)?;
        let status = UserStatus::from_str_checked(&self.status)?;

        Ok(User::reconstitute(
            self.id,
            email,
            password_hash,
            role,
            status,
            self.created_at,
            self.updated_at,
        ))
    }
}

// ── Refresh token row ──────────────────────────────────────────────────────────

#[derive(Debug, FromRow)]
pub struct RefreshTokenRow {
    pub id: Uuid,
    pub user_id: Uuid,
    pub token_hash: String,
    pub expires_at: DateTime<Utc>,
    pub revoked_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

impl From<RefreshTokenRow> for RefreshToken {
    fn from(row: RefreshTokenRow) -> Self {
        let mut token = RefreshToken::new(
            row.id,
            row.user_id,
            row.token_hash,
            row.expires_at,
            row.created_at,
        );
        if let Some(revoked) = row.revoked_at {
            token.revoke(revoked);
        }
        token
    }
}

// ── Outbox event row ───────────────────────────────────────────────────────────

#[derive(Debug, FromRow)]
pub struct OutboxEventRow {
    pub id: Uuid,
    pub aggregate_type: String,
    pub aggregate_id: Uuid,
    pub event_type: String,
    pub payload: serde_json::Value,
    pub metadata: serde_json::Value,
    pub status: String,
    pub occurred_at: DateTime<Utc>,
    pub published_at: Option<DateTime<Utc>>,
    pub retry_count: i32,
}

impl From<OutboxEventRow> for crate::domain::identity::repositories::outbox_repository::OutboxEvent {
    fn from(row: OutboxEventRow) -> Self {
        use crate::domain::identity::repositories::outbox_repository::OutboxStatus;
        Self {
            id: row.id,
            aggregate_type: row.aggregate_type,
            aggregate_id: row.aggregate_id,
            event_type: row.event_type,
            payload: row.payload,
            metadata: row.metadata,
            status: OutboxStatus::from_str_checked(&row.status),
            occurred_at: row.occurred_at,
            published_at: row.published_at,
            retry_count: row.retry_count,
        }
    }
}

// ── Inbox record row ───────────────────────────────────────────────────────────

#[derive(Debug, FromRow)]
pub struct InboxRecordRow {
    pub message_id: String,
    pub consumer_name: String,
    pub processed_at: DateTime<Utc>,
}
