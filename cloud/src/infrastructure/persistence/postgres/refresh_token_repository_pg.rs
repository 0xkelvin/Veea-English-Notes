use sqlx::PgPool;
use uuid::Uuid;

use crate::application::identity::transaction::PgTransaction;
use crate::domain::identity::repositories::refresh_token_repository::RefreshTokenRepository;
use crate::domain::identity::value_objects::refresh_token::RefreshToken;

use super::models::RefreshTokenRow;

pub struct PgRefreshTokenRepository {
    pool: PgPool,
}

impl PgRefreshTokenRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

impl RefreshTokenRepository for PgRefreshTokenRepository {
    async fn insert(&self, token: &RefreshToken) -> Result<(), anyhow::Error> {
        sqlx::query(
            "INSERT INTO refresh_tokens (id, user_id, token_hash, expires_at, revoked_at, created_at)
             VALUES ($1, $2, $3, $4, $5, $6)",
        )
        .bind(token.id)
        .bind(token.user_id)
        .bind(&token.token_hash)
        .bind(token.expires_at)
        .bind(token.revoked_at)
        .bind(token.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn find_by_token_hash(
        &self,
        token_hash: &str,
    ) -> Result<Option<RefreshToken>, anyhow::Error> {
        let row = sqlx::query_as::<_, RefreshTokenRow>(
            "SELECT id, user_id, token_hash, expires_at, revoked_at, created_at
             FROM refresh_tokens WHERE token_hash = $1",
        )
        .bind(token_hash)
        .fetch_optional(&self.pool)
        .await?;

        Ok(row.map(RefreshToken::from))
    }

    async fn revoke(
        &self,
        id: Uuid,
        revoked_at: chrono::DateTime<chrono::Utc>,
    ) -> Result<(), anyhow::Error> {
        sqlx::query("UPDATE refresh_tokens SET revoked_at = $1 WHERE id = $2")
            .bind(revoked_at)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn revoke_all_for_user(
        &self,
        user_id: Uuid,
        revoked_at: chrono::DateTime<chrono::Utc>,
    ) -> Result<u64, anyhow::Error> {
        let result = sqlx::query(
            "UPDATE refresh_tokens SET revoked_at = $1
             WHERE user_id = $2 AND revoked_at IS NULL",
        )
        .bind(revoked_at)
        .bind(user_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected())
    }
}

// ── Transactional variants ─────────────────────────────────────────────────────

use crate::application::identity::transaction::TransactionalRefreshTokenRepository;

impl TransactionalRefreshTokenRepository for PgRefreshTokenRepository {
    async fn insert_tx<'a>(
        &self,
        tx: &mut PgTransaction<'a>,
        token: &RefreshToken,
    ) -> Result<(), anyhow::Error> {
        sqlx::query(
            "INSERT INTO refresh_tokens (id, user_id, token_hash, expires_at, revoked_at, created_at)
             VALUES ($1, $2, $3, $4, $5, $6)",
        )
        .bind(token.id)
        .bind(token.user_id)
        .bind(&token.token_hash)
        .bind(token.expires_at)
        .bind(token.revoked_at)
        .bind(token.created_at)
        .execute(&mut **tx)
        .await?;
        Ok(())
    }

    async fn revoke_tx<'a>(
        &self,
        tx: &mut PgTransaction<'a>,
        id: Uuid,
        revoked_at: chrono::DateTime<chrono::Utc>,
    ) -> Result<(), anyhow::Error> {
        sqlx::query("UPDATE refresh_tokens SET revoked_at = $1 WHERE id = $2")
            .bind(revoked_at)
            .bind(id)
            .execute(&mut **tx)
            .await?;
        Ok(())
    }
}
