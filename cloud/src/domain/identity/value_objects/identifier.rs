use std::fmt;

use super::email::{Email, EmailError};
use super::phone_number::{PhoneNumber, PhoneNumberError};

/// What a user signs up and signs in with.
///
/// The client submits a single field and the server decides what it is, so
/// there is no "email or phone?" toggle to get wrong. Whichever kind it is
/// must be unique across all accounts.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Identifier {
    Email(Email),
    Phone(PhoneNumber),
}

impl Identifier {
    /// Parses a raw identifier, choosing the kind from its shape.
    ///
    /// The shape is decided before validation so that a malformed phone number
    /// reports a phone error rather than a confusing "invalid email".
    pub fn parse(raw: impl AsRef<str>) -> Result<Self, IdentifierError> {
        let raw = raw.as_ref().trim();

        if raw.is_empty() {
            return Err(IdentifierError::Empty);
        }

        if PhoneNumber::looks_like(raw) {
            return PhoneNumber::new(raw)
                .map(Identifier::Phone)
                .map_err(IdentifierError::Phone);
        }

        Email::new(raw)
            .map(Identifier::Email)
            .map_err(IdentifierError::Email)
    }

    pub fn as_email(&self) -> Option<&Email> {
        match self {
            Self::Email(email) => Some(email),
            Self::Phone(_) => None,
        }
    }

    pub fn as_phone(&self) -> Option<&PhoneNumber> {
        match self {
            Self::Phone(phone) => Some(phone),
            Self::Email(_) => None,
        }
    }

    /// The stored, normalised form.
    pub fn as_str(&self) -> &str {
        match self {
            Self::Email(email) => email.as_str(),
            Self::Phone(phone) => phone.as_str(),
        }
    }

    /// Short label used in logs and API responses.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Email(_) => "email",
            Self::Phone(_) => "phone",
        }
    }
}

impl fmt::Display for Identifier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum IdentifierError {
    #[error("enter an email address or a phone number")]
    Empty,

    #[error("{0}")]
    Email(#[source] EmailError),

    #[error("{0}")]
    Phone(#[source] PhoneNumberError),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_an_email_as_an_email() {
        let identifier = Identifier::parse("Kelvin@Example.com ").unwrap();
        assert_eq!(identifier.kind(), "email");
        // Email normalises to lowercase.
        assert_eq!(identifier.as_str(), "kelvin@example.com");
    }

    #[test]
    fn reads_a_phone_number_as_a_phone_number() {
        let identifier = Identifier::parse("+84 90 123 4567").unwrap();
        assert_eq!(identifier.kind(), "phone");
        assert_eq!(identifier.as_str(), "+84901234567");
    }

    #[test]
    fn a_malformed_phone_reports_a_phone_error() {
        // Not "invalid email", which is what a naive fallback would say.
        let error = Identifier::parse("+8490").unwrap_err();
        assert!(matches!(error, IdentifierError::Phone(_)));
    }

    #[test]
    fn a_malformed_email_reports_an_email_error() {
        let error = Identifier::parse("kelvin@").unwrap_err();
        assert!(matches!(error, IdentifierError::Email(_)));
    }

    #[test]
    fn rejects_blank_input() {
        assert_eq!(Identifier::parse("  "), Err(IdentifierError::Empty));
    }

    #[test]
    fn accessors_only_answer_for_their_own_kind() {
        let email = Identifier::parse("a@b.com").unwrap();
        assert!(email.as_email().is_some());
        assert!(email.as_phone().is_none());

        let phone = Identifier::parse("+84901234567").unwrap();
        assert!(phone.as_phone().is_some());
        assert!(phone.as_email().is_none());
    }
}
