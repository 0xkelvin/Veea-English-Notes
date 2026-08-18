use chrono::{DateTime, Utc};
use sqlx::FromRow;
use uuid::Uuid;

use crate::domain::identity::entities::user::User;
use crate::domain::identity::value_objects::email::Email;
use crate::domain::identity::value_objects::password_hash::PasswordHash;
use crate::domain::identity::value_objects::phone_number::PhoneNumber;
use crate::domain::identity::value_objects::refresh_token::RefreshToken;
use crate::domain::identity::value_objects::user_role::{UserRole, UserStatus};

// ── User row ───────────────────────────────────────────────────────────────────

#[derive(Debug, FromRow)]
pub struct UserRow {
    pub id: Uuid,
    /// Nullable since an account may be identified by phone alone. The
    /// `ck_users_has_identifier` constraint guarantees at least one is set.
    pub email: Option<String>,
    pub phone: Option<String>,
    pub password_hash: String,
    pub role: String,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl UserRow {
    pub fn into_domain(self) -> Result<User, anyhow::Error> {
        let email = self.email.map(Email::new).transpose()?;
        let phone = self.phone.map(PhoneNumber::new).transpose()?;
        let password_hash = PasswordHash::new(self.password_hash)?;
        let role = UserRole::from_str_checked(&self.role)?;
        let status = UserStatus::from_str_checked(&self.status)?;

        Ok(User::reconstitute(
            self.id,
            email,
            phone,
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

// ── Word row ───────────────────────────────────────────────────────────────────

use chrono::NaiveDate;

use crate::domain::vocabulary::entities::word::Word;
use crate::domain::vocabulary::repositories::word_repository::WordChange;
use crate::domain::vocabulary::value_objects::part_of_speech::PartOfSpeech;
use crate::domain::vocabulary::value_objects::word_text::{OptionalText, WordText};

#[derive(Debug, FromRow)]
pub struct WordRow {
    pub id: Uuid,
    pub user_id: Uuid,
    pub word: String,
    pub meaning: String,
    pub pronunciation: Option<String>,
    pub part_of_speech: Option<String>,
    pub source: Option<String>,
    pub examples: serde_json::Value,
    pub tags: serde_json::Value,
    pub day: NaiveDate,
    pub is_deleted: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl WordRow {
    pub fn into_domain(self) -> Result<Word, anyhow::Error> {
        Ok(Word::reconstitute(
            self.id,
            self.user_id,
            WordText::new(self.word)?,
            WordText::new(self.meaning)?,
            OptionalText::new(self.pronunciation)?,
            PartOfSpeech::from_optional(self.part_of_speech.as_deref())?,
            OptionalText::new(self.source)?,
            json_string_list(&self.examples),
            json_string_list(&self.tags),
            self.day,
            self.is_deleted,
            self.created_at,
            self.updated_at,
        ))
    }
}

/// A word row plus the server cursor, returned by the change feed.
#[derive(Debug, FromRow)]
pub struct WordChangeRow {
    #[sqlx(flatten)]
    pub word: WordRow,
    pub server_updated_at: DateTime<Utc>,
}

impl WordChangeRow {
    pub fn into_domain(self) -> Result<WordChange, anyhow::Error> {
        Ok(WordChange {
            word: self.word.into_domain()?,
            server_updated_at: self.server_updated_at,
        })
    }
}

/// Reads a JSONB array of strings, tolerating anything unexpected.
///
/// A malformed value yields an empty list rather than failing the whole sync —
/// losing one word's examples is far better than blocking every device.
fn json_string_list(value: &serde_json::Value) -> Vec<String> {
    value
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}
