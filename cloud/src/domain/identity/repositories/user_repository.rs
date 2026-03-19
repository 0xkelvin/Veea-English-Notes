use std::future::Future;

use uuid::Uuid;

use crate::domain::identity::entities::user::User;
use crate::domain::identity::value_objects::email::Email;

/// Port for user persistence.
///
/// Implementations live in the infrastructure layer (e.g. Postgres).
/// The domain and application layers depend only on this trait.
pub trait UserRepository: Send + Sync {
    /// Find a user by their primary key.
    fn find_by_id(&self, id: Uuid) -> impl Future<Output = Result<Option<User>, anyhow::Error>> + Send;

    /// Find a user by their email address.
    fn find_by_email(&self, email: &Email) -> impl Future<Output = Result<Option<User>, anyhow::Error>> + Send;

    /// Persist a new user.
    fn insert(&self, user: &User) -> impl Future<Output = Result<(), anyhow::Error>> + Send;

    /// Update an existing user.
    fn update(&self, user: &User) -> impl Future<Output = Result<(), anyhow::Error>> + Send;

    /// List users with pagination.
    fn list(
        &self,
        offset: u64,
        limit: u64,
    ) -> impl Future<Output = Result<(Vec<User>, u64), anyhow::Error>> + Send;
}
