use std::fmt;

/// Role assigned to a user within the identity bounded context.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UserRole {
    Admin,
    User,
}

impl UserRole {
    pub fn as_str(&self) -> &'static str {
        match self {
            UserRole::Admin => "admin",
            UserRole::User => "user",
        }
    }

    pub fn from_str_checked(s: &str) -> Result<Self, UserRoleError> {
        match s.to_lowercase().as_str() {
            "admin" => Ok(UserRole::Admin),
            "user" => Ok(UserRole::User),
            _ => Err(UserRoleError::Invalid(s.to_string())),
        }
    }

    pub fn is_admin(&self) -> bool {
        matches!(self, UserRole::Admin)
    }
}

impl fmt::Display for UserRole {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

/// User account status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UserStatus {
    Active,
    Suspended,
}

impl UserStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            UserStatus::Active => "active",
            UserStatus::Suspended => "suspended",
        }
    }

    pub fn from_str_checked(s: &str) -> Result<Self, UserStatusError> {
        match s.to_lowercase().as_str() {
            "active" => Ok(UserStatus::Active),
            "suspended" => Ok(UserStatus::Suspended),
            _ => Err(UserStatusError::Invalid(s.to_string())),
        }
    }

    pub fn is_active(&self) -> bool {
        matches!(self, UserStatus::Active)
    }
}

impl fmt::Display for UserStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum UserRoleError {
    #[error("invalid user role: {0}")]
    Invalid(String),
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum UserStatusError {
    #[error("invalid user status: {0}")]
    Invalid(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn role_round_trip() {
        assert_eq!(UserRole::from_str_checked("Admin").unwrap(), UserRole::Admin);
        assert_eq!(UserRole::from_str_checked("user").unwrap(), UserRole::User);
        assert_eq!(UserRole::Admin.as_str(), "admin");
    }

    #[test]
    fn invalid_role() {
        assert!(UserRole::from_str_checked("superadmin").is_err());
    }

    #[test]
    fn status_round_trip() {
        assert_eq!(UserStatus::from_str_checked("Active").unwrap(), UserStatus::Active);
        assert_eq!(UserStatus::from_str_checked("suspended").unwrap(), UserStatus::Suspended);
    }

    #[test]
    fn invalid_status() {
        assert!(UserStatus::from_str_checked("banned").is_err());
    }
}
