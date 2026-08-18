use std::fmt;

/// A phone number in E.164 form, e.g. `+84901234567`.
///
/// Stored normalised so the uniqueness constraint means what it says: without
/// normalisation `+84 90 123 4567` and `+84-901-234-567` would be two
/// different accounts.
///
/// An international prefix is required. A bare national number like
/// `0901234567` is not accepted, because resolving it needs a country the
/// server has no reliable way to know — guessing would silently hand the user
/// somebody else's number.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PhoneNumber(String);

impl PhoneNumber {
    /// E.164 allows at most 15 digits after the `+`.
    pub const MAX_DIGITS: usize = 15;

    /// Shortest plausible international number. The true minimum varies by
    /// country; this only rejects obvious nonsense.
    pub const MIN_DIGITS: usize = 8;

    pub fn new(raw: impl Into<String>) -> Result<Self, PhoneNumberError> {
        let raw = raw.into();
        let trimmed = raw.trim();

        if trimmed.is_empty() {
            return Err(PhoneNumberError::Empty);
        }

        // `00` is the other common way to write an international prefix.
        let body = trimmed
            .strip_prefix('+')
            .or_else(|| trimmed.strip_prefix("00"))
            .ok_or(PhoneNumberError::MissingCountryCode)?;

        // Spacing, dashes, dots and parentheses are presentation, not data.
        let digits: String = body
            .chars()
            .filter(|c| !matches!(c, ' ' | '-' | '.' | '(' | ')' | '\u{a0}'))
            .collect();

        if !digits.chars().all(|c| c.is_ascii_digit()) {
            return Err(PhoneNumberError::InvalidCharacters);
        }
        if digits.len() < Self::MIN_DIGITS {
            return Err(PhoneNumberError::TooShort);
        }
        if digits.len() > Self::MAX_DIGITS {
            return Err(PhoneNumberError::TooLong);
        }
        // A country code never starts with 0.
        if digits.starts_with('0') {
            return Err(PhoneNumberError::MissingCountryCode);
        }

        Ok(Self(format!("+{digits}")))
    }

    /// True when the input looks like an attempt at a phone number.
    ///
    /// Used to decide which value object a submitted identifier should become,
    /// so a typo'd phone number reports a phone error rather than an email one.
    pub fn looks_like(raw: &str) -> bool {
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.contains('@') {
            return false;
        }
        let first_is_prefix =
            trimmed.starts_with('+') || trimmed.starts_with('0') || trimmed.starts_with("00");
        first_is_prefix
            && trimmed
                .chars()
                .all(|c| c.is_ascii_digit() || matches!(c, '+' | ' ' | '-' | '.' | '(' | ')'))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_inner(self) -> String {
        self.0
    }
}

impl fmt::Display for PhoneNumber {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PhoneNumberError {
    #[error("phone number must not be empty")]
    Empty,

    #[error("include the country code, e.g. +84901234567")]
    MissingCountryCode,

    #[error("phone number may only contain digits and spacing")]
    InvalidCharacters,

    #[error("phone number is too short")]
    TooShort,

    #[error("phone number is too long")]
    TooLong,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalises_presentation_characters() {
        // All four spellings are one account.
        for raw in [
            "+84901234567",
            "+84 90 123 4567",
            "+84-901-234-567",
            "+84 (901) 234.567",
        ] {
            assert_eq!(PhoneNumber::new(raw).unwrap().as_str(), "+84901234567");
        }
    }

    #[test]
    fn accepts_the_double_zero_prefix() {
        assert_eq!(
            PhoneNumber::new("0084901234567").unwrap().as_str(),
            "+84901234567"
        );
    }

    #[test]
    fn rejects_a_national_number() {
        // Ambiguous without a country; guessing would be worse than refusing.
        assert_eq!(
            PhoneNumber::new("0901234567"),
            Err(PhoneNumberError::MissingCountryCode)
        );
    }

    #[test]
    fn rejects_a_number_with_no_prefix_at_all() {
        assert_eq!(
            PhoneNumber::new("84901234567"),
            Err(PhoneNumberError::MissingCountryCode)
        );
    }

    #[test]
    fn rejects_letters() {
        assert_eq!(
            PhoneNumber::new("+84CALLNOW1"),
            Err(PhoneNumberError::InvalidCharacters)
        );
    }

    #[test]
    fn enforces_the_length_bounds() {
        assert_eq!(PhoneNumber::new("+123456"), Err(PhoneNumberError::TooShort));
        assert_eq!(
            PhoneNumber::new("+1234567890123456"),
            Err(PhoneNumberError::TooLong)
        );
    }

    #[test]
    fn rejects_blank_input() {
        assert_eq!(PhoneNumber::new("   "), Err(PhoneNumberError::Empty));
    }

    #[test]
    fn recognises_phone_shaped_input() {
        assert!(PhoneNumber::looks_like("+84901234567"));
        assert!(PhoneNumber::looks_like("0901234567"));
        assert!(PhoneNumber::looks_like("+84 90 123 4567"));

        assert!(!PhoneNumber::looks_like("you@example.com"));
        assert!(!PhoneNumber::looks_like("kelvin"));
        assert!(!PhoneNumber::looks_like(""));
    }
}
