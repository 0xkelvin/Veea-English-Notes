use std::fmt;

/// A non-empty, length-bounded piece of user text.
///
/// Used for the word itself and its meaning. Trimming happens here so the
/// invariant ("not blank") cannot be satisfied by whitespace alone, which the
/// database CHECK constraint also enforces as a backstop.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct WordText(String);

impl WordText {
    /// Longest accepted value. Generous — a "word" may be an idiom or a short
    /// phrase — but bounded so a client cannot post unbounded text.
    pub const MAX_LEN: usize = 512;

    pub fn new(raw: impl Into<String>) -> Result<Self, WordTextError> {
        let value = raw.into().trim().to_string();

        if value.is_empty() {
            return Err(WordTextError::Empty);
        }
        if value.chars().count() > Self::MAX_LEN {
            return Err(WordTextError::TooLong);
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

impl fmt::Display for WordText {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum WordTextError {
    #[error("must not be empty")]
    Empty,

    #[error("must be at most {} characters", WordText::MAX_LEN)]
    TooLong,
}

/// Optional free text, e.g. pronunciation or where the word was encountered.
///
/// Blank input normalises to `None` so the database never stores an empty
/// string where the absence of a value is what was meant.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct OptionalText(Option<String>);

impl OptionalText {
    pub const MAX_LEN: usize = 1024;

    pub fn new(raw: Option<impl Into<String>>) -> Result<Self, WordTextError> {
        let Some(value) = raw else {
            return Ok(Self(None));
        };
        let value = value.into().trim().to_string();

        if value.is_empty() {
            return Ok(Self(None));
        }
        if value.chars().count() > Self::MAX_LEN {
            return Err(WordTextError::TooLong);
        }

        Ok(Self(Some(value)))
    }

    pub fn as_deref(&self) -> Option<&str> {
        self.0.as_deref()
    }

    pub fn into_inner(self) -> Option<String> {
        self.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trims_surrounding_whitespace() {
        assert_eq!(
            WordText::new("  resilient  ").unwrap().as_str(),
            "resilient"
        );
    }

    #[test]
    fn rejects_blank_input() {
        assert_eq!(WordText::new("   "), Err(WordTextError::Empty));
        assert_eq!(WordText::new(""), Err(WordTextError::Empty));
    }

    #[test]
    fn counts_characters_not_bytes() {
        // Vietnamese is multi-byte; a byte-length check would reject valid input.
        let value = "ê".repeat(WordText::MAX_LEN);
        assert!(WordText::new(value).is_ok());
    }

    #[test]
    fn rejects_overlong_input() {
        let value = "a".repeat(WordText::MAX_LEN + 1);
        assert_eq!(WordText::new(value), Err(WordTextError::TooLong));
    }

    #[test]
    fn blank_optional_text_becomes_none() {
        assert_eq!(OptionalText::new(Some("  ")).unwrap().as_deref(), None);
        assert_eq!(OptionalText::new(None::<String>).unwrap().as_deref(), None);
    }
}
