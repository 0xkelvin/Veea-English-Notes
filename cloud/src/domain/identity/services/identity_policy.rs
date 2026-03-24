use uuid::Uuid;

use crate::domain::identity::errors::IdentityError;
use crate::domain::identity::value_objects::user_role::UserRole;

/// Domain policy service for identity authorization rules.
///
/// Encapsulates business rules that involve cross-aggregate or cross-entity
/// checks that don't naturally belong on a single aggregate.
///
/// Making this a plain function module (no state) keeps it testable
/// without any infrastructure dependencies.
pub struct IdentityPolicy;

impl IdentityPolicy {
    /// Check whether the acting user is allowed to change another user's role.
    ///
    /// Rules:
    /// - Only admins can change roles.
    /// - A user cannot escalate their own role to admin (unless already admin).
    /// - An admin CAN demote themselves (intentional design choice).
    pub fn can_change_role(
        actor_id: Uuid,
        actor_role: &UserRole,
        target_user_id: Uuid,
        new_role: &UserRole,
    ) -> Result<(), IdentityError> {
        if !actor_role.is_admin() {
            return Err(IdentityError::InsufficientPermissions(
                "only admins can change user roles".to_string(),
            ));
        }

        // Prevent non-admin self-escalation (already guaranteed by the check
        // above, but be explicit about the self-promotion case)
        if actor_id == target_user_id && new_role.is_admin() && !actor_role.is_admin() {
            return Err(IdentityError::SelfRoleEscalation);
        }

        Ok(())
    }

    /// Check if the acting user can view another user's profile.
    ///
    /// - Users can view their own profile.
    /// - Admins can view any profile.
    pub fn can_view_profile(
        actor_id: Uuid,
        actor_role: &UserRole,
        target_user_id: Uuid,
    ) -> Result<(), IdentityError> {
        if actor_id == target_user_id || actor_role.is_admin() {
            return Ok(());
        }
        Err(IdentityError::InsufficientPermissions(
            "cannot view other user profiles".to_string(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn admin_can_change_role() {
        let admin_id = Uuid::new_v4();
        let target_id = Uuid::new_v4();
        let result = IdentityPolicy::can_change_role(
            admin_id,
            &UserRole::Admin,
            target_id,
            &UserRole::Admin,
        );
        assert!(result.is_ok());
    }

    #[test]
    fn user_cannot_change_role() {
        let user_id = Uuid::new_v4();
        let target_id = Uuid::new_v4();
        let result = IdentityPolicy::can_change_role(
            user_id,
            &UserRole::User,
            target_id,
            &UserRole::Admin,
        );
        assert!(result.is_err());
    }

    #[test]
    fn user_can_view_own_profile() {
        let user_id = Uuid::new_v4();
        let result = IdentityPolicy::can_view_profile(user_id, &UserRole::User, user_id);
        assert!(result.is_ok());
    }

    #[test]
    fn user_cannot_view_others_profile() {
        let user_id = Uuid::new_v4();
        let other_id = Uuid::new_v4();
        let result = IdentityPolicy::can_view_profile(user_id, &UserRole::User, other_id);
        assert!(result.is_err());
    }

    #[test]
    fn admin_can_view_any_profile() {
        let admin_id = Uuid::new_v4();
        let other_id = Uuid::new_v4();
        let result = IdentityPolicy::can_view_profile(admin_id, &UserRole::Admin, other_id);
        assert!(result.is_ok());
    }
}
