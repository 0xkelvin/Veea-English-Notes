use std::future::Future;

use chrono::NaiveDate;
use uuid::Uuid;

use crate::domain::vocabulary::entities::vocabulary_word::VocabularyWord;

pub trait VocabularyRepository: Send + Sync {
    fn find_by_id(
        &self,
        id: Uuid,
        user_id: Uuid,
    ) -> impl Future<Output = Result<Option<VocabularyWord>, anyhow::Error>> + Send;

    fn list_by_user(
        &self,
        user_id: Uuid,
    ) -> impl Future<Output = Result<Vec<VocabularyWord>, anyhow::Error>> + Send;

    fn list_due(
        &self,
        user_id: Uuid,
        today: NaiveDate,
    ) -> impl Future<Output = Result<Vec<VocabularyWord>, anyhow::Error>> + Send;

    fn insert(
        &self,
        word: &VocabularyWord,
    ) -> impl Future<Output = Result<(), anyhow::Error>> + Send;

    fn update(
        &self,
        word: &VocabularyWord,
    ) -> impl Future<Output = Result<(), anyhow::Error>> + Send;

    fn delete(
        &self,
        id: Uuid,
        user_id: Uuid,
    ) -> impl Future<Output = Result<bool, anyhow::Error>> + Send;
}
