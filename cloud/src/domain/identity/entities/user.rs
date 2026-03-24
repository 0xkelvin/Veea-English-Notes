use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::domain::identity::errors::IdentityError;
use crate::domain::identity::events::{
    IdentityDomainEvent, UserRegistered, UserRoleChanged,
};
use crate::domain::identity::value_objects::email::Email;
use crate::domain::identity::value_objects::password_hash::PasswordHash;
use crate::domain::identity::value_objects::user_role::{UserRole, UserStatus};

/// The User aggregate root for the Identity bounded context.
///
/// All mutations go through methods that enforce domain invariants
/// and collect domain events for later publication via the outbox.
#[derive(Debug, Clone)]
pub struct User {
    pub id: Uuid,
    pub email: Email,
    pub password_hash: PasswordHash,
    pub role: UserRole,
    pub status: UserStatus,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    /// Domain events raised during the current unit of work.
    /// Drained by the application layer after persisting the aggregate.
    events: Vec<IdentityDomainEvent>,
}

impl User {
    // ------------------------------------------------------------------
    // Factory
    // ------------------------------------------------------------------

    /// Register a new user.
    ///
    /// Assigns the `User` role by default and raises `UserRegistered`.
    pub fn register(
        id: Uuid,
        email: Email,
        password_hash: PasswordHash,
        now: DateTime<Utc>,
    ) -> Self {
        let mut user = Self {
            id,
            email: email.clone(),
            password_hash,
            role: UserRole::User,
            status: UserStatus::Active,
            created_at: now,
            updated_at: now,
            events: Vec::new(),
        };

        user.events.push(IdentityDomainEvent::UserRegistered(UserRegistered {
            user_id: user.id,
            email: email.as_str().to_string(),
            role: user.role.as_str().to_string(),
            occurred_at: now,
        }));

        user
    }

    /// Reconstitute from persistence — no events are raised.
    pub fn reconstitute(
        id: Uuid,
        email: Email,
        password_hash: PasswordHash,
        role: UserRole,
        status: UserStatus,
        created_at: DateTime<Utc>,
        updated_at: DateTime<Utc>,
    ) -> Self {
        Self {
            id,
            email,
            password_hash,
            role,
            status,
            created_at,
            updated_at,
            events: Vec::new(),
        }
    }

    // ------------------------------------------------------------------
    // Behavior
    // ------------------------------------------------------------------

    /// Verify that the user account is active and allowed to authenticate.
    pub fn ensure_active(&self) -> Result<(), IdentityError> {
        if !self.status.is_active() {
            return Err(IdentityError::AccountSuspended);
        }
        Ok(())
    }

    /// Change the user's role.
    ///
    /// Domain invariants:
    /// - A user cannot escalate their own role.
    /// - Only admins may change roles (enforced at the policy layer).
    pub fn change_role(
        &mut self,
        new_role: UserRole,
        changed_by: Uuid,
        now: DateTime<Utc>,
    ) -> Result<(), IdentityError> {
        // Prevent self-escalation
        if changed_by == self.id && new_role.is_admin() && !self.role.is_admin() {
            return Err(IdentityError::SelfRoleEscalation);
        }

        let old_role = self.role;
        if old_role == new_role {
            return Ok(()); // no-op
        }

        self.role = new_role;
        self.updated_at = now;

        self.events.push(IdentityDomainEvent::UserRoleChanged(UserRoleChanged {
            user_id: self.id,
            old_role: old_role.as_str().to_string(),
            new_role: new_role.as_str().to_string(),
            changed_by,
            occurred_at: now,
        }));

        Ok(())
    }

    /// Suspend the account.
    pub fn suspend(&mut self, now: DateTime<Utc>) {
        self.status = UserStatus::Suspended;
        self.updated_at = now;
    }

    /// Reactivate the account.
    pub fn activate(&mut self, now: DateTime<Utc>) {
        self.status = UserStatus::Active;
        self.updated_at = now;
    }

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    /// Drain all pending domain events (consumed after persistence).
    pub fn take_events(&mut self) -> Vec<IdentityDomainEvent> {
        std::mem::take(&mut self.events)
    }

    pub fn pending_events(&self) -> &[IdentityDomainEvent] {
        &self.events
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_user() -> User {
        User::register(
            Uuid::new_v4(),
            Email::new("test@example.com").unwrap(),
            PasswordHash::new("$argon2id$hash").unwrap(),
            Utc::now(),
        )
    }

    #[test]
    fn register_creates_active_user_with_user_role() {
        let user = make_user();
        assert_eq!(user.role, UserRole::User);
        assert_eq!(user.status, UserStatus::Active);
        assert_eq!(user.pending_events().len(), 1);
    }

    #[test]
    fn change_role_raises_event() {
        let admin_id = Uuid::new_v4();
        let mut user = make_user();
        user.change_role(UserRole::Admin, admin_id, Utc::now()).unwrap();
        assert_eq!(user.role, UserRole::Admin);
        // 1 from register + 1 from role change
        assert_eq!(user.pending_events().len(), 2);
    }

    #[test]
    fn self_escalation_prevented() {
        let mut user = make_user();
        let user_id = user.id;
        let result = user.change_role(UserRole::Admin, user_id, Utc::now());
        assert_eq!(result, Err(IdentityError::SelfRoleEscalation));
    }

    #[test]
    fn same_role_is_noop() {
        let admin_id = Uuid::new_v4();
        let mut user = make_user();
        user.change_role(UserRole::User, admin_id, Utc::now()).unwrap();
        // Only the register event
        assert_eq!(user.pending_events().len(), 1);
    }

    #[test]
    fn suspended_user_fails_ensure_active() {
        let mut user = make_user();
        user.suspend(Utc::now());
        assert_eq!(user.ensure_active(), Err(IdentityError::AccountSuspended));
    }

    #[test]
    fn take_events_drains() {
        let mut user = make_user();
        let events = user.take_events();
        assert_eq!(events.len(), 1);
        assert!(user.pending_events().is_empty());
    }
}

