pub mod user_deleted;
pub mod user_identifier_changed;
pub mod user_password_changed;
pub mod user_registered;
pub mod user_role_changed;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub use user_deleted::UserDeleted;
pub use user_identifier_changed::UserIdentifierChanged;
pub use user_password_changed::UserPasswordChanged;
pub use user_registered::UserRegistered;
pub use user_role_changed::UserRoleChanged;

/// Envelope for all domain events in the identity bounded context.
///
/// Each variant carries the event payload and can be serialized
/// for outbox persistence and messaging publication.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "event_type", content = "payload")]
pub enum IdentityDomainEvent {
    UserRegistered(UserRegistered),
    UserRoleChanged(UserRoleChanged),
    UserPasswordChanged(UserPasswordChanged),
    UserIdentifierChanged(UserIdentifierChanged),
    UserDeleted(UserDeleted),
}

impl IdentityDomainEvent {
    pub fn event_type(&self) -> &'static str {
        match self {
            IdentityDomainEvent::UserRegistered(_) => "identity.user_registered",
            IdentityDomainEvent::UserRoleChanged(_) => "identity.user_role_changed",
            IdentityDomainEvent::UserPasswordChanged(_) => "identity.user_password_changed",
            IdentityDomainEvent::UserIdentifierChanged(_) => "identity.user_identifier_changed",
            IdentityDomainEvent::UserDeleted(_) => "identity.user_deleted",
        }
    }

    pub fn aggregate_type(&self) -> &'static str {
        "User"
    }

    pub fn aggregate_id(&self) -> Uuid {
        match self {
            IdentityDomainEvent::UserRegistered(e) => e.user_id,
            IdentityDomainEvent::UserRoleChanged(e) => e.user_id,
            IdentityDomainEvent::UserPasswordChanged(e) => e.user_id,
            IdentityDomainEvent::UserIdentifierChanged(e) => e.user_id,
            IdentityDomainEvent::UserDeleted(e) => e.user_id,
        }
    }

    pub fn occurred_at(&self) -> DateTime<Utc> {
        match self {
            IdentityDomainEvent::UserRegistered(e) => e.occurred_at,
            IdentityDomainEvent::UserRoleChanged(e) => e.occurred_at,
            IdentityDomainEvent::UserPasswordChanged(e) => e.occurred_at,
            IdentityDomainEvent::UserIdentifierChanged(e) => e.occurred_at,
            IdentityDomainEvent::UserDeleted(e) => e.occurred_at,
        }
    }
}
