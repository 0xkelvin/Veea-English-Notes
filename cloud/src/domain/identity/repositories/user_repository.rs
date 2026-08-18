use std::future::Future;

use uuid::Uuid;

use crate::domain::identity::entities::user::User;
use crate::domain::identity::value_objects::identifier::Identifier;

/// Port for user persistence.
///
/// Implementations live in the infrastructure layer (e.g. Postgres).
/// The domain and application layers depend only on this trait.
pub trait UserRepository: Send + Sync {
    /// Find a user by their primary key.
    fn find_by_id(&self, id: Uuid)
    -> impl Future<Output = Result<Option<User>, anyhow::Error>> + Send;

    /// Find a user by the email address or phone number they sign in with.
    ///
    /// The lookup checks the column matching the identifier's kind, so an
    /// email is never matched against a phone column or vice versa.
    fn find_by_identifier(
        &self,
        identifier: &Identifier,
    ) -> impl Future<Output = Result<Option<User>, anyhow::Error>> + Send;

    /// Persist a new user.
    fn insert(&self, user: &User) -> impl Future<Output = Result<(), anyhow::Error>> + Send;

    /// Update an existing user.
    fn update(&self, user: &User) -> impl Future<Output = Result<(), anyhow::Error>> + Send;

    /// Permanently remove a user.
    ///
    /// Everything owned by the account goes with it via `ON DELETE CASCADE`,
    /// so this is the single point where a deletion becomes irreversible.
    fn delete(&self, id: Uuid) -> impl Future<Output = Result<(), anyhow::Error>> + Send;

    /// List users with pagination.
    fn list(
        &self,
        offset: u64,
        limit: u64,
    ) -> impl Future<Output = Result<(Vec<User>, u64), anyhow::Error>> + Send;
}
