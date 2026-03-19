use sqlx::PgPool;
use uuid::Uuid;

use crate::application::identity::transaction::PgTransaction;
use crate::domain::identity::entities::user::User;
use crate::domain::identity::repositories::user_repository::UserRepository;
use crate::domain::identity::value_objects::email::Email;

use super::models::UserRow;

/// Postgres-backed implementation of `UserRepository`.
pub struct PgUserRepository {
    pool: PgPool,
}

impl PgUserRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

impl UserRepository for PgUserRepository {
    async fn find_by_id(&self, id: Uuid) -> Result<Option<User>, anyhow::Error> {
        let row = sqlx::query_as::<_, UserRow>(
            "SELECT id, email, password_hash, role, status, created_at, updated_at
             FROM users WHERE id = $1",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;

        row.map(UserRow::into_domain).transpose()
    }

    async fn find_by_email(&self, email: &Email) -> Result<Option<User>, anyhow::Error> {
        let row = sqlx::query_as::<_, UserRow>(
            "SELECT id, email, password_hash, role, status, created_at, updated_at
             FROM users WHERE email = $1",
        )
        .bind(email.as_str())
        .fetch_optional(&self.pool)
        .await?;

        row.map(UserRow::into_domain).transpose()
    }

    async fn insert(&self, user: &User) -> Result<(), anyhow::Error> {
        sqlx::query(
            "INSERT INTO users (id, email, password_hash, role, status, created_at, updated_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7)",
        )
        .bind(user.id)
        .bind(user.email.as_str())
        .bind(user.password_hash.as_str())
        .bind(user.role.as_str())
        .bind(user.status.as_str())
        .bind(user.created_at)
        .bind(user.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn update(&self, user: &User) -> Result<(), anyhow::Error> {
        sqlx::query(
            "UPDATE users SET email = $1, password_hash = $2, role = $3,
                              status = $4, updated_at = $5
             WHERE id = $6",
        )
        .bind(user.email.as_str())
        .bind(user.password_hash.as_str())
        .bind(user.role.as_str())
        .bind(user.status.as_str())
        .bind(user.updated_at)
        .bind(user.id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn list(&self, offset: u64, limit: u64) -> Result<(Vec<User>, u64), anyhow::Error> {
        let total: (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM users")
                .fetch_one(&self.pool)
                .await?;

        let rows = sqlx::query_as::<_, UserRow>(
            "SELECT id, email, password_hash, role, status, created_at, updated_at
             FROM users ORDER BY created_at DESC LIMIT $1 OFFSET $2",
        )
        .bind(limit as i64)
        .bind(offset as i64)
        .fetch_all(&self.pool)
        .await?;

        let users = rows
            .into_iter()
            .map(UserRow::into_domain)
            .collect::<Result<Vec<_>, _>>()?;

        Ok((users, total.0 as u64))
    }
}

// ── Transactional variants ─────────────────────────────────────────────────────

use crate::application::identity::transaction::TransactionalUserRepository;

impl TransactionalUserRepository for PgUserRepository {
    async fn insert_tx<'a>(
        &self,
        tx: &mut PgTransaction<'a>,
        user: &User,
    ) -> Result<(), anyhow::Error> {
        sqlx::query(
            "INSERT INTO users (id, email, password_hash, role, status, created_at, updated_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7)",
        )
        .bind(user.id)
        .bind(user.email.as_str())
        .bind(user.password_hash.as_str())
        .bind(user.role.as_str())
        .bind(user.status.as_str())
        .bind(user.created_at)
        .bind(user.updated_at)
        .execute(&mut **tx)
        .await?;
        Ok(())
    }

    async fn update_tx<'a>(
        &self,
        tx: &mut PgTransaction<'a>,
        user: &User,
    ) -> Result<(), anyhow::Error> {
        sqlx::query(
            "UPDATE users SET email = $1, password_hash = $2, role = $3,
                              status = $4, updated_at = $5
             WHERE id = $6",
        )
        .bind(user.email.as_str())
        .bind(user.password_hash.as_str())
        .bind(user.role.as_str())
        .bind(user.status.as_str())
        .bind(user.updated_at)
        .bind(user.id)
        .execute(&mut **tx)
        .await?;
        Ok(())
    }
}
