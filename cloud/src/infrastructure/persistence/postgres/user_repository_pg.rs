use sqlx::PgPool;
use uuid::Uuid;

use crate::application::identity::transaction::PgTransaction;
use crate::domain::identity::entities::user::User;
use crate::domain::identity::repositories::user_repository::UserRepository;
use crate::domain::identity::value_objects::identifier::Identifier;

use super::models::UserRow;

/// Postgres-backed implementation of `UserRepository`.
pub struct PgUserRepository {
    pool: PgPool,
}

impl PgUserRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Columns shared by every read, so the projection cannot drift from
    /// [`UserRow`].
    const COLUMNS: &'static str =
        "id, email, phone, password_hash, role, status, created_at, updated_at";
}

impl UserRepository for PgUserRepository {
    async fn find_by_id(&self, id: Uuid) -> Result<Option<User>, anyhow::Error> {
        let row = sqlx::query_as::<_, UserRow>(&format!(
            "SELECT {} FROM users WHERE id = $1",
            Self::COLUMNS
        ))
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;

        row.map(UserRow::into_domain).transpose()
    }

    async fn find_by_identifier(
        &self,
        identifier: &Identifier,
    ) -> Result<Option<User>, anyhow::Error> {
        // Matching on the kind keeps an email from ever being compared against
        // the phone column, which a single `email = $1 OR phone = $1` would
        // allow.
        let sql = match identifier {
            Identifier::Email(_) => {
                format!("SELECT {} FROM users WHERE email = $1", Self::COLUMNS)
            }
            Identifier::Phone(_) => {
                format!("SELECT {} FROM users WHERE phone = $1", Self::COLUMNS)
            }
        };

        let row = sqlx::query_as::<_, UserRow>(&sql)
            .bind(identifier.as_str())
            .fetch_optional(&self.pool)
            .await?;

        row.map(UserRow::into_domain).transpose()
    }

    async fn insert(&self, user: &User) -> Result<(), anyhow::Error> {
        sqlx::query(
            "INSERT INTO users (id, email, phone, password_hash, role, status, created_at, updated_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
        )
        .bind(user.id)
        .bind(user.email.as_ref().map(|e| e.as_str()))
        .bind(user.phone.as_ref().map(|p| p.as_str()))
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
            "UPDATE users SET email = $1, phone = $2, password_hash = $3, role = $4,
                              status = $5, updated_at = $6
             WHERE id = $7",
        )
        .bind(user.email.as_ref().map(|e| e.as_str()))
        .bind(user.phone.as_ref().map(|p| p.as_str()))
        .bind(user.password_hash.as_str())
        .bind(user.role.as_str())
        .bind(user.status.as_str())
        .bind(user.updated_at)
        .bind(user.id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn delete(&self, id: Uuid) -> Result<(), anyhow::Error> {
        // Words and refresh tokens both declare ON DELETE CASCADE, so this one
        // statement removes everything the account owns.
        sqlx::query("DELETE FROM users WHERE id = $1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn list(&self, offset: u64, limit: u64) -> Result<(Vec<User>, u64), anyhow::Error> {
        let total: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM users")
            .fetch_one(&self.pool)
            .await?;

        let rows = sqlx::query_as::<_, UserRow>(&format!(
            "SELECT {} FROM users ORDER BY created_at DESC LIMIT $1 OFFSET $2",
            Self::COLUMNS
        ))
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
            "INSERT INTO users (id, email, phone, password_hash, role, status, created_at, updated_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
        )
        .bind(user.id)
        .bind(user.email.as_ref().map(|e| e.as_str()))
        .bind(user.phone.as_ref().map(|p| p.as_str()))
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
            "UPDATE users SET email = $1, phone = $2, password_hash = $3, role = $4,
                              status = $5, updated_at = $6
             WHERE id = $7",
        )
        .bind(user.email.as_ref().map(|e| e.as_str()))
        .bind(user.phone.as_ref().map(|p| p.as_str()))
        .bind(user.password_hash.as_str())
        .bind(user.role.as_str())
        .bind(user.status.as_str())
        .bind(user.updated_at)
        .bind(user.id)
        .execute(&mut **tx)
        .await?;
        Ok(())
    }

    async fn delete_tx<'a>(
        &self,
        tx: &mut PgTransaction<'a>,
        id: Uuid,
    ) -> Result<(), anyhow::Error> {
        sqlx::query("DELETE FROM users WHERE id = $1")
            .bind(id)
            .execute(&mut **tx)
            .await?;
        Ok(())
    }
}
