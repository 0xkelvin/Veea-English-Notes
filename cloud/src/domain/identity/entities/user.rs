use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::domain::identity::errors::IdentityError;
use crate::domain::identity::events::{
    IdentityDomainEvent, UserDeleted, UserIdentifierChanged, UserPasswordChanged, UserRegistered,
    UserRoleChanged,
};
use crate::domain::identity::value_objects::email::Email;
use crate::domain::identity::value_objects::identifier::Identifier;
use crate::domain::identity::value_objects::password_hash::PasswordHash;
use crate::domain::identity::value_objects::phone_number::PhoneNumber;
use crate::domain::identity::value_objects::user_role::{UserRole, UserStatus};

/// The User aggregate root for the Identity bounded context.
///
/// All mutations go through methods that enforce domain invariants
/// and collect domain events for later publication via the outbox.
///
/// An account is identified by an email address, a phone number, or both.
/// At least one must always be present: an account with neither could never be
/// signed into again, so [`change_identifier`](Self::change_identifier) is the
/// only way to move between them and it always leaves one in place.
#[derive(Debug, Clone)]
pub struct User {
    pub id: Uuid,
    pub email: Option<Email>,
    pub phone: Option<PhoneNumber>,
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

    /// Register a new user against an email address or a phone number.
    ///
    /// Assigns the `User` role by default and raises `UserRegistered`.
    pub fn register(
        id: Uuid,
        identifier: Identifier,
        password_hash: PasswordHash,
        now: DateTime<Utc>,
    ) -> Self {
        let (email, phone) = match identifier.clone() {
            Identifier::Email(email) => (Some(email), None),
            Identifier::Phone(phone) => (None, Some(phone)),
        };

        let mut user = Self {
            id,
            email,
            phone,
            password_hash,
            role: UserRole::User,
            status: UserStatus::Active,
            created_at: now,
            updated_at: now,
            events: Vec::new(),
        };

        user.events
            .push(IdentityDomainEvent::UserRegistered(UserRegistered {
                user_id: user.id,
                identifier: identifier.as_str().to_string(),
                identifier_kind: identifier.kind().to_string(),
                role: user.role.as_str().to_string(),
                occurred_at: now,
            }));

        user
    }

    /// Reconstitute from persistence — no events are raised.
    #[allow(clippy::too_many_arguments)]
    pub fn reconstitute(
        id: Uuid,
        email: Option<Email>,
        phone: Option<PhoneNumber>,
        password_hash: PasswordHash,
        role: UserRole,
        status: UserStatus,
        created_at: DateTime<Utc>,
        updated_at: DateTime<Utc>,
    ) -> Self {
        Self {
            id,
            email,
            phone,
            password_hash,
            role,
            status,
            created_at,
            updated_at,
            events: Vec::new(),
        }
    }

    // ------------------------------------------------------------------
    // Identifiers
    // ------------------------------------------------------------------

    /// The identifier shown to the user and embedded in access tokens.
    ///
    /// Email is preferred when both are set, because that is what the account
    /// was most likely created with. The database `CHECK` guarantees one
    /// exists, so the fallback is unreachable in practice.
    pub fn primary_identifier(&self) -> String {
        self.email
            .as_ref()
            .map(|e| e.as_str().to_string())
            .or_else(|| self.phone.as_ref().map(|p| p.as_str().to_string()))
            .unwrap_or_default()
    }

    /// Replaces the identifier of whichever kind [`new_identifier`] is,
    /// leaving the other kind untouched.
    ///
    /// Adding a phone to an email account, or vice versa, therefore keeps both
    /// and the account remains reachable either way.
    pub fn change_identifier(
        &mut self,
        new_identifier: Identifier,
        now: DateTime<Utc>,
    ) -> Result<(), IdentityError> {
        let previous = self.primary_identifier();

        match new_identifier.clone() {
            Identifier::Email(email) => {
                if self.email.as_ref() == Some(&email) {
                    return Ok(()); // no-op
                }
                self.email = Some(email);
            }
            Identifier::Phone(phone) => {
                if self.phone.as_ref() == Some(&phone) {
                    return Ok(());
                }
                self.phone = Some(phone);
            }
        }

        self.updated_at = now;
        self.events.push(IdentityDomainEvent::UserIdentifierChanged(
            UserIdentifierChanged {
                user_id: self.id,
                previous_identifier: previous,
                new_identifier: new_identifier.as_str().to_string(),
                identifier_kind: new_identifier.kind().to_string(),
                occurred_at: now,
            },
        ));

        Ok(())
    }

    /// Removes one identifier, refusing if it is the only one left.
    pub fn remove_identifier(
        &mut self,
        kind: IdentifierKind,
        now: DateTime<Utc>,
    ) -> Result<(), IdentityError> {
        match kind {
            IdentifierKind::Email if self.phone.is_some() => self.email = None,
            IdentifierKind::Phone if self.email.is_some() => self.phone = None,
            // Removing the last identifier would strand the account.
            _ => return Err(IdentityError::LastIdentifierRemoved),
        }
        self.updated_at = now;
        Ok(())
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

    /// Replace the password hash.
    ///
    /// The caller is responsible for having verified the current password
    /// first; the aggregate only records the change.
    pub fn change_password(&mut self, new_hash: PasswordHash, now: DateTime<Utc>) {
        self.password_hash = new_hash;
        self.updated_at = now;

        self.events.push(IdentityDomainEvent::UserPasswordChanged(
            UserPasswordChanged {
                user_id: self.id,
                occurred_at: now,
            },
        ));
    }

    /// Raise the event marking this account for deletion.
    ///
    /// The row itself is removed by the repository; this exists so downstream
    /// consumers learn about it through the outbox like every other change.
    pub fn mark_deleted(&mut self, now: DateTime<Utc>) {
        self.events
            .push(IdentityDomainEvent::UserDeleted(UserDeleted {
                user_id: self.id,
                identifier: self.primary_identifier(),
                occurred_at: now,
            }));
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

        self.events
            .push(IdentityDomainEvent::UserRoleChanged(UserRoleChanged {
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

/// Which identifier a removal targets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdentifierKind {
    Email,
    Phone,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identifier(raw: &str) -> Identifier {
        Identifier::parse(raw).unwrap()
    }

    fn make_user() -> User {
        User::register(
            Uuid::new_v4(),
            identifier("test@example.com"),
            PasswordHash::new("$argon2id$hash").unwrap(),
            Utc::now(),
        )
    }

    fn make_phone_user() -> User {
        User::register(
            Uuid::new_v4(),
            identifier("+84901234567"),
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
    fn registering_with_an_email_leaves_the_phone_unset() {
        let user = make_user();
        assert!(user.email.is_some());
        assert!(user.phone.is_none());
        assert_eq!(user.primary_identifier(), "test@example.com");
    }

    #[test]
    fn registering_with_a_phone_leaves_the_email_unset() {
        let user = make_phone_user();
        assert!(user.phone.is_some());
        assert!(user.email.is_none());
        assert_eq!(user.primary_identifier(), "+84901234567");
    }

    #[test]
    fn adding_a_phone_to_an_email_account_keeps_both() {
        let mut user = make_user();
        user.change_identifier(identifier("+84901234567"), Utc::now())
            .unwrap();

        assert!(user.email.is_some());
        assert!(user.phone.is_some());
        // Email stays primary; it is what the account was created with.
        assert_eq!(user.primary_identifier(), "test@example.com");
    }

    #[test]
    fn changing_an_email_replaces_only_the_email() {
        let mut user = make_user();
        user.change_identifier(identifier("+84901234567"), Utc::now())
            .unwrap();
        user.change_identifier(identifier("new@example.com"), Utc::now())
            .unwrap();

        assert_eq!(user.email.as_ref().unwrap().as_str(), "new@example.com");
        assert_eq!(user.phone.as_ref().unwrap().as_str(), "+84901234567");
    }

    #[test]
    fn setting_the_same_identifier_raises_no_event() {
        let mut user = make_user();
        user.take_events();
        user.change_identifier(identifier("test@example.com"), Utc::now())
            .unwrap();
        assert!(user.pending_events().is_empty());
    }

    #[test]
    fn changing_an_identifier_raises_an_event() {
        let mut user = make_user();
        user.take_events();
        user.change_identifier(identifier("new@example.com"), Utc::now())
            .unwrap();
        assert_eq!(user.pending_events().len(), 1);
    }

    #[test]
    fn the_last_identifier_cannot_be_removed() {
        let mut user = make_user();
        assert_eq!(
            user.remove_identifier(IdentifierKind::Email, Utc::now()),
            Err(IdentityError::LastIdentifierRemoved)
        );
        assert!(user.email.is_some());
    }

    #[test]
    fn an_identifier_can_be_removed_while_another_remains() {
        let mut user = make_user();
        user.change_identifier(identifier("+84901234567"), Utc::now())
            .unwrap();

        user.remove_identifier(IdentifierKind::Email, Utc::now())
            .unwrap();

        assert!(user.email.is_none());
        assert_eq!(user.primary_identifier(), "+84901234567");
    }

    #[test]
    fn changing_the_password_raises_an_event() {
        let mut user = make_user();
        user.take_events();
        user.change_password(PasswordHash::new("$argon2id$new").unwrap(), Utc::now());

        assert_eq!(user.password_hash.as_str(), "$argon2id$new");
        assert_eq!(user.pending_events().len(), 1);
    }

    #[test]
    fn deletion_raises_an_event_carrying_the_identifier() {
        let mut user = make_user();
        user.take_events();
        user.mark_deleted(Utc::now());

        match &user.pending_events()[0] {
            IdentityDomainEvent::UserDeleted(event) => {
                assert_eq!(event.identifier, "test@example.com");
            }
            other => panic!("expected UserDeleted, got {other:?}"),
        }
    }

    #[test]
    fn change_role_raises_event() {
        let admin_id = Uuid::new_v4();
        let mut user = make_user();
        user.change_role(UserRole::Admin, admin_id, Utc::now())
            .unwrap();
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
        user.change_role(UserRole::User, admin_id, Utc::now())
            .unwrap();
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
