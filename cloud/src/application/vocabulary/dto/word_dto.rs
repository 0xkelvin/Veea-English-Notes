use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::domain::vocabulary::entities::word::Word;
use crate::domain::vocabulary::errors::VocabularyError;
use crate::domain::vocabulary::value_objects::part_of_speech::PartOfSpeech;
use crate::domain::vocabulary::value_objects::word_text::{OptionalText, WordText};

/// Wire representation of a word, in both directions.
///
/// Field names are camelCase to match the Flutter client's JSON.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WordPayload {
    pub id: Uuid,
    pub word: String,
    pub meaning: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pronunciation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub part_of_speech: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(default)]
    pub examples: Vec<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    /// `YYYY-MM-DD`.
    pub date: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    #[serde(default)]
    pub deleted: bool,
}

impl WordPayload {
    /// Validates the payload and binds it to an owner.
    ///
    /// `user_id` comes from the verified JWT, never from the request body —
    /// otherwise a client could file words under somebody else's account.
    pub fn into_domain(self, user_id: Uuid) -> Result<Word, VocabularyError> {
        let word = WordText::new(self.word).map_err(VocabularyError::InvalidWord)?;
        let meaning = WordText::new(self.meaning).map_err(VocabularyError::InvalidMeaning)?;
        let pronunciation =
            OptionalText::new(self.pronunciation).map_err(VocabularyError::InvalidPronunciation)?;
        let source = OptionalText::new(self.source).map_err(VocabularyError::InvalidSource)?;
        let part_of_speech = PartOfSpeech::from_optional(self.part_of_speech.as_deref())?;

        let day = NaiveDate::parse_from_str(&self.date, "%Y-%m-%d")
            .map_err(|_| VocabularyError::InvalidDay(self.date.clone()))?;

        Ok(Word::reconstitute(
            self.id,
            user_id,
            word,
            meaning,
            pronunciation,
            part_of_speech,
            source,
            Word::normalise_list(self.examples),
            Word::normalise_list(self.tags),
            day,
            self.deleted,
            self.created_at,
            self.updated_at,
        ))
    }
}

impl From<&Word> for WordPayload {
    fn from(word: &Word) -> Self {
        Self {
            id: word.id,
            word: word.word.as_str().to_string(),
            meaning: word.meaning.as_str().to_string(),
            pronunciation: word.pronunciation.as_deref().map(str::to_string),
            part_of_speech: word.part_of_speech.map(|p| p.as_str().to_string()),
            source: word.source.as_deref().map(str::to_string),
            examples: word.examples.clone(),
            tags: word.tags.clone(),
            date: word.day.format("%Y-%m-%d").to_string(),
            created_at: word.created_at,
            updated_at: word.updated_at,
            deleted: word.is_deleted,
        }
    }
}

/// Request body for `POST /api/v1/vocabulary/sync`.
///
/// Push and pull are one call so no change can slip between them.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncRequest {
    /// Local rows the server has not acknowledged. May be empty on a
    /// pull-only sync.
    #[serde(default)]
    pub changes: Vec<WordPayload>,

    /// Highest `serverTime` the client has already applied. `None` requests a
    /// full download.
    #[serde(default)]
    pub since: Option<DateTime<Utc>>,
}

/// Response body for `POST /api/v1/vocabulary/sync`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncResponse {
    /// Ids from `changes` that were stored. Anything missing was rejected as
    /// stale or not owned, and the client should re-pull rather than retry.
    pub accepted: Vec<Uuid>,

    /// Rows changed since the requested cursor, including tombstones.
    pub changes: Vec<WordPayload>,

    /// Cursor for the next pull. Only advance the local cursor to this value
    /// once every row in `changes` has been applied.
    pub server_time: DateTime<Utc>,

    /// True when `changes` was capped and another pull is needed immediately.
    pub has_more: bool,
}
