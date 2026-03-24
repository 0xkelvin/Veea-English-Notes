use std::future::Future;

/// Transaction abstraction for multi-repository writes.
///
/// Commands that must write to multiple tables atomically
/// (e.g. insert user + insert outbox event) use this port.
///
/// The infrastructure layer implements this with a real sqlx transaction.
/// We use a concrete sqlx::Transaction type to avoid GAT complexity in
/// command handler signatures while keeping the transaction boundary explicit.
pub use sqlx::PgPool;

/// Begin a transaction from a pool.
pub async fn begin_tx(
    pool: &PgPool,
) -> Result<sqlx::Transaction<'_, sqlx::Postgres>, anyhow::Error> {
    Ok(pool.begin().await?)
}

/// Shorthand type alias for the Postgres transaction.
pub type PgTransaction<'a> = sqlx::Transaction<'a, sqlx::Postgres>;

/// Transactional repository operations.
///
/// Repository traits that support transactional writes implement
/// a `_tx` variant that accepts the transaction handle.
pub trait TransactionalUserRepository: Send + Sync {
    fn insert_tx<'a>(
        &self,
        tx: &mut PgTransaction<'a>,
        user: &crate::domain::identity::entities::user::User,
    ) -> impl Future<Output = Result<(), anyhow::Error>> + Send;

    fn update_tx<'a>(
        &self,
        tx: &mut PgTransaction<'a>,
        user: &crate::domain::identity::entities::user::User,
    ) -> impl Future<Output = Result<(), anyhow::Error>> + Send;
}

pub trait TransactionalOutboxRepository: Send + Sync {
    fn insert_tx<'a>(
        &self,
        tx: &mut PgTransaction<'a>,
        event: &crate::domain::identity::repositories::outbox_repository::OutboxEvent,
    ) -> impl Future<Output = Result<(), anyhow::Error>> + Send;
}

pub trait TransactionalRefreshTokenRepository: Send + Sync {
    fn insert_tx<'a>(
        &self,
        tx: &mut PgTransaction<'a>,
        token: &crate::domain::identity::value_objects::refresh_token::RefreshToken,
    ) -> impl Future<Output = Result<(), anyhow::Error>> + Send;

    fn revoke_tx<'a>(
        &self,
        tx: &mut PgTransaction<'a>,
        id: uuid::Uuid,
        revoked_at: chrono::DateTime<chrono::Utc>,
    ) -> impl Future<Output = Result<(), anyhow::Error>> + Send;
}
