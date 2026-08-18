use super::value_objects::part_of_speech::PartOfSpeechError;
use super::value_objects::word_text::WordTextError;

/// Domain errors for the Vocabulary bounded context.
///
/// Business-rule violations only; infrastructure failures surface as
/// `anyhow::Error` and are mapped to `AppError::Internal`.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum VocabularyError {
    #[error("word not found")]
    WordNotFound,

    #[error("word belongs to another user")]
    NotOwned,

    #[error("invalid word: {0}")]
    InvalidWord(WordTextError),

    #[error("invalid meaning: {0}")]
    InvalidMeaning(WordTextError),

    #[error("invalid pronunciation: {0}")]
    InvalidPronunciation(WordTextError),

    #[error("invalid source: {0}")]
    InvalidSource(WordTextError),

    #[error("invalid part of speech: {0}")]
    InvalidPartOfSpeech(#[from] PartOfSpeechError),

    #[error("invalid day: {0}")]
    InvalidDay(String),

    #[error("too many changes in one batch: {0}")]
    BatchTooLarge(usize),
}
