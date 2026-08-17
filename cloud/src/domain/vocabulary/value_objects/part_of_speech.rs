/// Grammatical category of a word.
///
/// Persisted as a short stable code so the variants can be reordered or
/// renamed without a data migration. Mirrors `PartOfSpeech` in the Flutter
/// client — the codes must stay in step across both.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PartOfSpeech {
    Noun,
    Verb,
    Adjective,
    Adverb,
    Phrase,
    Idiom,
    Other,
}

impl PartOfSpeech {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Noun => "n",
            Self::Verb => "v",
            Self::Adjective => "adj",
            Self::Adverb => "adv",
            Self::Phrase => "phr",
            Self::Idiom => "idm",
            Self::Other => "etc",
        }
    }

    pub fn from_str_checked(value: &str) -> Result<Self, PartOfSpeechError> {
        match value {
            "n" => Ok(Self::Noun),
            "v" => Ok(Self::Verb),
            "adj" => Ok(Self::Adjective),
            "adv" => Ok(Self::Adverb),
            "phr" => Ok(Self::Phrase),
            "idm" => Ok(Self::Idiom),
            "etc" => Ok(Self::Other),
            other => Err(PartOfSpeechError::Unknown(other.to_string())),
        }
    }

    /// Parses an optional code, treating a blank string as absent.
    pub fn from_optional(value: Option<&str>) -> Result<Option<Self>, PartOfSpeechError> {
        match value.map(str::trim) {
            None | Some("") => Ok(None),
            Some(code) => Self::from_str_checked(code).map(Some),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PartOfSpeechError {
    #[error("unknown part of speech: {0}")]
    Unknown(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_every_variant() {
        for value in [
            PartOfSpeech::Noun,
            PartOfSpeech::Verb,
            PartOfSpeech::Adjective,
            PartOfSpeech::Adverb,
            PartOfSpeech::Phrase,
            PartOfSpeech::Idiom,
            PartOfSpeech::Other,
        ] {
            assert_eq!(PartOfSpeech::from_str_checked(value.as_str()), Ok(value));
        }
    }

    #[test]
    fn treats_blank_as_absent() {
        assert_eq!(PartOfSpeech::from_optional(Some("  ")), Ok(None));
        assert_eq!(PartOfSpeech::from_optional(None), Ok(None));
    }

    #[test]
    fn rejects_an_unknown_code() {
        assert!(PartOfSpeech::from_optional(Some("noun")).is_err());
    }
}
