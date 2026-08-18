use super::value_objects::email::EmailError;
use super::value_objects::identifier::IdentifierError;
use super::value_objects::password_hash::PasswordHashError;
use super::value_objects::user_role::{UserRoleError, UserStatusError};

/// Domain errors for the Identity bounded context.
///
/// These represent business-rule violations, not infrastructure failures.
/// The application layer maps them to appropriate HTTP status codes.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum IdentityError {
    #[error("user not found")]
    UserNotFound,

    #[error("that email or phone number is already registered")]
    IdentifierAlreadyExists(String),

    #[error("an account must keep at least one email address or phone number")]
    LastIdentifierRemoved,

    #[error("invalid identifier: {0}")]
    InvalidIdentifier(#[from] IdentifierError),

    #[error("invalid credentials")]
    InvalidCredentials,

    #[error("account is suspended")]
    AccountSuspended,

    #[error("refresh token not found")]
    RefreshTokenNotFound,

    #[error("refresh token expired")]
    RefreshTokenExpired,

    #[error("refresh token revoked")]
    RefreshTokenRevoked,

    #[error("insufficient permissions: {0}")]
    InsufficientPermissions(String),

    #[error("cannot escalate own role")]
    SelfRoleEscalation,

    #[error("invalid email: {0}")]
    InvalidEmail(#[from] EmailError),

    #[error("invalid password hash: {0}")]
    InvalidPasswordHash(#[from] PasswordHashError),

    #[error("invalid role: {0}")]
    InvalidRole(#[from] UserRoleError),

    #[error("invalid status: {0}")]
    InvalidStatus(#[from] UserStatusError),
}
