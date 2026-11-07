use tracing::instrument;
use uuid::Uuid;

use crate::application::vocabulary::dto::word_dto::{SyncRequest, SyncResponse, WordPayload};
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::domain::vocabulary::entities::word::Word;
use crate::domain::vocabulary::errors::VocabularyError;
use crate::domain::vocabulary::repositories::word_repository::WordRepository;

/// Largest batch a client may push in one call.
pub const MAX_BATCH: usize = 500;

/// Largest page of changes returned in one pull.
pub const MAX_PULL: i64 = 500;

#[derive(Debug)]
pub struct SyncWordsCommand {
    pub user_id: Uuid,
    pub request: SyncRequest,
}

/// Applies the client's pending changes and returns everything it has not
/// seen yet.
///
/// The pull deliberately runs *after* the push, and its cursor is the server
/// clock rather than the client's, so a device immediately sees the canonical
/// result of its own upload — including any write that lost a conflict.
#[instrument(skip_all, fields(user_id = %command.user_id, pushed = command.request.changes.len()))]
pub async fn handle<R: WordRepository>(
    command: SyncWordsCommand,
    repo: &R,
) -> AppResult<SyncResponse> {
    let SyncWordsCommand { user_id, request } = command;

    if request.changes.len() > MAX_BATCH {
        return Err(AppError::Validation(
            VocabularyError::BatchTooLarge(request.changes.len()).to_string(),
        ));
    }

    let revision = request
        .cursor
        .as_ref()
        .map(|s| s.parse::<i64>().ok().filter(|n| *n >= 0))
        .map(|v| v.ok_or_else(|| AppError::Validation("Invalid sync cursor".into())))
        .transpose()?;
    // Validate the whole batch before writing any of it, so a single bad row
    // cannot leave the upload half-applied.
    let words = request
        .changes
        .into_iter()
        .map(|payload| payload.into_domain(user_id))
        .collect::<Result<Vec<Word>, VocabularyError>>()
        .map_err(|error| AppError::Validation(error.to_string()))?;

    let accepted = if words.is_empty() {
        Vec::new()
    } else {
        repo.upsert_batch(user_id, &words).await?
    };

    // Ask for one extra row to detect whether another page is waiting, without
    // a second count query.
    let mut changes = repo
        .changes_since(user_id, request.since, revision, MAX_PULL + 1)
        .await?;

    let has_more = changes.len() as i64 > MAX_PULL;
    if has_more {
        changes.truncate(MAX_PULL as usize);
    }

    // The cursor is the last row actually returned, never "now": rows written
    // between the query and the response would otherwise be skipped forever.
    let server_time = changes
        .last()
        .map(|change| change.server_updated_at)
        .or(request.since)
        .unwrap_or_else(chrono::Utc::now);

    // Stale uploads can lose to rows older than the current pull cursor.
    // Always return the winning owned row so the client can replace its draft.
    let mut canonical = Vec::with_capacity(accepted.len());
    for id in &accepted {
        if let Some(word) = repo.find_by_id(user_id, *id).await? {
            canonical.push(WordPayload::from(&word));
        }
    }
    let cursor = changes
        .last()
        .map(|c| c.sync_revision)
        .or(revision)
        .unwrap_or(0)
        .to_string();
    Ok(SyncResponse {
        accepted,
        canonical,
        cursor,
        changes: changes
            .iter()
            .map(|change| WordPayload::from(&change.word))
            .collect(),
        server_time,
        has_more,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::vocabulary::repositories::word_repository::WordChange;
    use chrono::{DateTime, Utc};
    struct Repo {
        rows: Vec<WordChange>,
    }
    impl WordRepository for Repo {
        async fn upsert_batch(&self, _: Uuid, words: &[Word]) -> Result<Vec<Uuid>, anyhow::Error> {
            Ok(words.iter().map(|w| w.id).collect())
        }
        async fn changes_since(
            &self,
            _: Uuid,
            since: Option<DateTime<Utc>>,
            revision: Option<i64>,
            limit: i64,
        ) -> Result<Vec<WordChange>, anyhow::Error> {
            Ok(self
                .rows
                .iter()
                .filter(|r| {
                    revision.map_or_else(
                        || since.is_none_or(|s| r.server_updated_at > s),
                        |n| r.sync_revision > n,
                    )
                })
                .take(limit as usize)
                .cloned()
                .collect())
        }
        async fn find_by_id(&self, _: Uuid, id: Uuid) -> Result<Option<Word>, anyhow::Error> {
            Ok(self
                .rows
                .iter()
                .find(|r| r.word.id == id)
                .map(|r| r.word.clone()))
        }
        async fn list(&self, _: Uuid, _: i64, _: i64) -> Result<(Vec<Word>, u64), anyhow::Error> {
            unimplemented!()
        }
    }
    fn rows() -> Repo {
        let timestamp = Utc::now();
        Repo {
            rows: (1..=501)
                .map(|n| WordChange {
                    sync_revision: n,
                    server_updated_at: timestamp,
                    word: WordPayload {
                        id: Uuid::new_v4(),
                        word: format!("word{n}"),
                        meaning: "meaning".into(),
                        pronunciation: None,
                        part_of_speech: None,
                        source: None,
                        examples: vec![],
                        tags: vec![],
                        date: "2026-11-07".into(),
                        created_at: timestamp,
                        updated_at: timestamp,
                        deleted: false,
                    }
                    .into_domain(Uuid::nil())
                    .unwrap(),
                })
                .collect(),
        }
    }
    #[tokio::test]
    async fn revision_cursor_does_not_skip_a_shared_timestamp_page() {
        let repo = rows();
        let first = handle(
            SyncWordsCommand {
                user_id: Uuid::nil(),
                request: SyncRequest {
                    changes: vec![],
                    since: None,
                    cursor: Some("0".into()),
                },
            },
            &repo,
        )
        .await
        .unwrap();
        assert!(first.has_more);
        assert_eq!(first.changes.len(), 500);
        assert_eq!(first.cursor, "500");
        let second = handle(
            SyncWordsCommand {
                user_id: Uuid::nil(),
                request: SyncRequest {
                    changes: vec![],
                    since: Some(first.server_time),
                    cursor: Some(first.cursor),
                },
            },
            &repo,
        )
        .await
        .unwrap();
        assert!(!second.has_more);
        assert_eq!(second.changes.len(), 1);
        assert_eq!(second.cursor, "501");
    }
    #[tokio::test]
    async fn stale_upload_gets_canonical_winner_even_before_pull_cursor() {
        let repo = rows();
        let mut stale = WordPayload::from(&repo.rows[0].word);
        stale.meaning = "stale draft".into();
        let response = handle(
            SyncWordsCommand {
                user_id: Uuid::nil(),
                request: SyncRequest {
                    changes: vec![stale],
                    since: None,
                    cursor: Some("501".into()),
                },
            },
            &repo,
        )
        .await
        .unwrap();
        assert!(response.changes.is_empty());
        assert_eq!(response.canonical[0].meaning, "meaning");
        assert_eq!(response.accepted.len(), 1);
    }
    #[tokio::test]
    async fn invalid_cursor_is_rejected_before_any_write() {
        let response = handle(
            SyncWordsCommand {
                user_id: Uuid::nil(),
                request: SyncRequest {
                    changes: vec![],
                    since: None,
                    cursor: Some("-1".into()),
                },
            },
            &rows(),
        )
        .await;
        assert!(response.is_err());
    }
}
