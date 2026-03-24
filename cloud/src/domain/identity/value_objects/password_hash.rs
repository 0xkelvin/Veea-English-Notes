use std::fmt;

/// An opaque password hash produced by the `PasswordHasher` port.
///
/// The domain never sees plaintext passwords — only pre-hashed values.
/// Invariant: must not be empty.
#[derive(Clone, PartialEq, Eq)]
pub struct PasswordHash(String);

impl PasswordHash {
    pub fn new(hash: impl Into<String>) -> Result<Self, PasswordHashError> {
        let value = hash.into();
        if value.is_empty() {
            return Err(PasswordHashError::Empty);
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

/// Never print the hash in debug/display output.
impl fmt::Debug for PasswordHash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "PasswordHash([REDACTED])")
    }
}

impl fmt::Display for PasswordHash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[REDACTED]")
    }
}

/// Reconstruct from a trusted source (e.g. database row).
impl From<String> for PasswordHash {
    fn from(s: String) -> Self {
        Self(s)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PasswordHashError {
    #[error("password hash cannot be empty")]
    Empty,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_hash() {
        let hash = PasswordHash::new("$argon2id$v=19$...").unwrap();
        assert_eq!(hash.as_str(), "$argon2id$v=19$...");
    }

    #[test]
    fn empty_hash_rejected() {
        assert_eq!(PasswordHash::new(""), Err(PasswordHashError::Empty));
    }

    #[test]
    fn debug_redacts() {
        let hash = PasswordHash::new("secret").unwrap();
        assert_eq!(format!("{hash:?}"), "PasswordHash([REDACTED])");
    }
}
