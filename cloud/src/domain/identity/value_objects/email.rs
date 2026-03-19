use std::fmt;

/// Validated email address value object.
///
/// Invariant: must match a basic email pattern. Stored as lowercase.
/// This is a domain-level check — full RFC 5322 compliance is
/// intentionally not enforced here (mail delivery is the real validator).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Email(String);

impl Email {
    /// Create a new `Email` from a raw string.
    ///
    /// Returns `Err` if the string doesn't look like a plausible email.
    pub fn new(raw: impl Into<String>) -> Result<Self, EmailError> {
        let value = raw.into().trim().to_lowercase();

        if value.is_empty() {
            return Err(EmailError::Empty);
        }
        if value.len() > 254 {
            return Err(EmailError::TooLong);
        }

        // Must contain exactly one '@' with non-empty local and domain parts
        let parts: Vec<&str> = value.splitn(2, '@').collect();
        if parts.len() != 2 {
            return Err(EmailError::InvalidFormat);
        }

        let local = parts[0];
        let domain = parts[1];

        if local.is_empty() || local.len() > 64 {
            return Err(EmailError::InvalidFormat);
        }
        if domain.is_empty() || !domain.contains('.') {
            return Err(EmailError::InvalidFormat);
        }

        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_inner(self) -> String {
        self.0
    }
}

impl fmt::Display for Email {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Reconstruct an `Email` from a trusted source (e.g. database) without re-validation.
impl From<String> for Email {
    fn from(s: String) -> Self {
        Self(s)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum EmailError {
    #[error("email cannot be empty")]
    Empty,
    #[error("email exceeds maximum length of 254 characters")]
    TooLong,
    #[error("email format is invalid")]
    InvalidFormat,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_email() {
        let email = Email::new("Alice@Example.COM").unwrap();
        assert_eq!(email.as_str(), "alice@example.com");
    }

    #[test]
    fn empty_email() {
        assert_eq!(Email::new(""), Err(EmailError::Empty));
    }

    #[test]
    fn missing_at_sign() {
        assert_eq!(Email::new("nodomain"), Err(EmailError::InvalidFormat));
    }

    #[test]
    fn missing_domain_dot() {
        assert_eq!(Email::new("user@localhost"), Err(EmailError::InvalidFormat));
    }

    #[test]
    fn trims_whitespace() {
        let email = Email::new("  user@test.com  ").unwrap();
        assert_eq!(email.as_str(), "user@test.com");
    }
}
