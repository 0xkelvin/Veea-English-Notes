use super::commands::support::{build_outbox_event, generate_refresh_token, hash_refresh_token};
use super::ports::{
    clock::Clock,
    id_generator::IdGenerator,
    jwt_service::{AccessTokenClaims, JwtService},
    password_hasher::PasswordHasher,
};
use super::transaction::{
    TransactionalOutboxRepository, TransactionalRefreshTokenRepository, TransactionalUserRepository,
};
use crate::common::{error::AppError, result::AppResult};
use crate::domain::identity::{
    entities::user::User,
    repositories::user_repository::UserRepository,
    value_objects::{
        identifier::Identifier, password_hash::PasswordHash, refresh_token::RefreshToken,
    },
};
use crate::infrastructure::security::otp_delivery::OtpDelivery;
use chrono::Duration;
use serde::Serialize;
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use uuid::Uuid;

pub fn vietnam_phone(raw: &str) -> AppResult<String> {
    let compact: String = raw
        .trim()
        .chars()
        .filter(|c| !matches!(c, ' ' | '-' | '.' | '(' | ')'))
        .collect();
    let national = compact
        .strip_prefix("+84")
        .or_else(|| compact.strip_prefix('0'))
        .unwrap_or(&compact);
    if national.len() != 9
        || !national.bytes().all(|b| b.is_ascii_digit())
        || !matches!(national.as_bytes()[0], b'3' | b'5' | b'7' | b'8' | b'9')
    {
        return Err(AppError::Validation(
            "Enter a Vietnamese mobile number, for example 0901234567.".into(),
        ));
    }
    Ok(format!("+84{national}"))
}

#[derive(Serialize)]
pub struct ChallengeResponse {
    pub challenge_id: Uuid,
    pub expires_in: i64,
    pub retry_after: i64,
}

pub async fn request_challenge(
    pool: &PgPool,
    delivery: &impl OtpDelivery,
    phone: &str,
    purpose: &str,
    user_id: Option<Uuid>,
    ip: &str,
) -> AppResult<ChallengeResponse> {
    if !delivery.available() {
        return Err(AppError::Unavailable(
            "Phone sign-in is not available yet. Your words remain saved on this device.".into(),
        ));
    }
    let phone = vietnam_phone(phone)?;
    let ip_hash = hex::encode(Sha256::digest(ip.as_bytes()));
    let mut tx = pool.begin().await?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
        .bind(format!("otp-ip:{ip_hash}"))
        .execute(&mut *tx)
        .await?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
        .bind(format!("otp-phone:{phone}"))
        .execute(&mut *tx)
        .await?;
    let counts: (i64, i64, i64) = sqlx::query_as("SELECT COUNT(*) FILTER (WHERE created_at > now() - INTERVAL '60 seconds'), COUNT(*) FILTER (WHERE created_at > now() - INTERVAL '1 hour'), COUNT(*) FROM otp_challenges WHERE phone = $1 AND created_at > now() - INTERVAL '1 day'")
        .bind(&phone).fetch_one(&mut *tx).await?;
    let ip_count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM otp_challenges WHERE ip_hash = $1 AND created_at > now() - INTERVAL '1 hour'").bind(&ip_hash).fetch_one(&mut *tx).await?;
    if counts.0 > 0 || counts.1 >= 5 || counts.2 >= 20 || ip_count.0 >= 20 {
        return Err(AppError::RateLimitExceeded);
    }
    let id = Uuid::new_v4();
    sqlx::query("INSERT INTO otp_challenges(id,phone,ip_hash,purpose,user_id,expires_at) VALUES($1,$2,$3,$4,$5,now() + INTERVAL '10 minutes')")
        .bind(id).bind(&phone).bind(ip_hash).bind(purpose).bind(user_id).execute(&mut *tx).await?;
    tx.commit().await?;
    let sid = delivery.send(&phone).await?;
    sqlx::query("UPDATE otp_challenges SET provider_sid = $1 WHERE id = $2")
        .bind(sid)
        .bind(id)
        .execute(pool)
        .await?;
    // Short-lived challenges contain phone numbers; retain only the window needed for abuse controls.
    sqlx::query("DELETE FROM otp_challenges WHERE created_at < now() - INTERVAL '2 days'")
        .execute(pool)
        .await?;
    Ok(ChallengeResponse {
        challenge_id: id,
        expires_in: 600,
        retry_after: 60,
    })
}

pub async fn consume_challenge(
    pool: &PgPool,
    delivery: &impl OtpDelivery,
    id: Uuid,
    code: &str,
    purpose: &str,
    user_id: Option<Uuid>,
) -> AppResult<String> {
    let invalid = || {
        AppError::Validation(
            "That code is incorrect or expired. Please try again or request a new code.".into(),
        )
    };
    if code.len() < 4 || code.len() > 10 || !code.bytes().all(|b| b.is_ascii_digit()) {
        return Err(invalid());
    }
    let row: Option<(String, Option<String>)> = sqlx::query_as("UPDATE otp_challenges SET attempts = attempts + 1 WHERE id = $1 AND purpose = $2 AND user_id IS NOT DISTINCT FROM $3 AND consumed_at IS NULL AND expires_at > now() AND attempts < 5 AND provider_sid IS NOT NULL RETURNING phone, provider_sid")
        .bind(id).bind(purpose).bind(user_id).fetch_optional(pool).await?;
    let (phone, sid) = row.ok_or_else(invalid)?;
    if !delivery
        .check(&sid.ok_or_else(invalid)?, &phone, code)
        .await?
    {
        return Err(invalid());
    }
    let used = sqlx::query("UPDATE otp_challenges SET consumed_at = now() WHERE id = $1 AND consumed_at IS NULL AND expires_at > now()")
        .bind(id).execute(pool).await?;
    if used.rows_affected() != 1 {
        return Err(invalid());
    }
    Ok(phone)
}

#[allow(clippy::too_many_arguments)]
pub async fn sign_in_verified(
    phone: String,
    pool: &PgPool,
    users: &(impl UserRepository + TransactionalUserRepository),
    refresh: &impl TransactionalRefreshTokenRepository,
    outbox: &impl TransactionalOutboxRepository,
    hasher: &impl PasswordHasher,
    jwt: &impl JwtService,
    clock: &impl Clock,
    ids: &impl IdGenerator,
    access_secs: i64,
    refresh_secs: i64,
) -> AppResult<serde_json::Value> {
    let now = clock.now();
    let mut tx = pool.begin().await?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
        .bind(&phone)
        .execute(&mut *tx)
        .await?;
    let previous: Option<(Uuid, String)> =
        sqlx::query_as("SELECT id, auth_method FROM users WHERE phone = $1 FOR UPDATE")
            .bind(&phone)
            .fetch_optional(&mut *tx)
            .await?;
    let user = if let Some((id, method)) = previous {
        let user = users.find_by_id(id).await?.ok_or(AppError::Unauthorized)?;
        user.ensure_active().map_err(|_| AppError::Forbidden)?;
        if method != "phone_otp" {
            // Legacy phone claims were not verified. Do not silently migrate or
            // merge those notebooks through this new login flow.
            return Err(AppError::Conflict(
                "This older account needs a migration. Please contact Veea support.".into(),
            ));
        }
        user
    } else {
        let secret = PasswordHash::new(hasher.hash_password(&generate_refresh_token()).await?)
            .map_err(|e| AppError::Validation(e.to_string()))?;
        let identifier =
            Identifier::parse(&phone).map_err(|e| AppError::Validation(e.to_string()))?;
        let mut user = User::register(ids.new_id(), identifier, secret, now);
        users.insert_tx(&mut tx, &user).await?;
        for event in user.take_events() {
            outbox
                .insert_tx(&mut tx, &build_outbox_event(&event, ids, now)?)
                .await?;
        }
        user
    };
    sqlx::query("UPDATE users SET auth_method = 'phone_otp', phone_verified_at = COALESCE(phone_verified_at, $1) WHERE id = $2").bind(now).bind(user.id).execute(&mut *tx).await?;
    let raw = generate_refresh_token();
    refresh
        .insert_tx(
            &mut tx,
            &RefreshToken::new(
                ids.new_id(),
                user.id,
                hash_refresh_token(&raw),
                now + Duration::seconds(refresh_secs),
                now,
            ),
        )
        .await?;
    let access = jwt.create_access_token(&AccessTokenClaims {
        sub: user.id,
        email: user.primary_identifier(),
        role: user.role.as_str().into(),
        jti: ids.new_id(),
        iat: now,
        exp: now + Duration::seconds(access_secs),
    })?;
    tx.commit().await?;
    Ok(
        serde_json::json!({"user_id": user.id, "identifier": phone, "auth_method":"phone_otp", "tokens": {"access_token":access,"refresh_token":raw,"expires_in":access_secs,"token_type":"Bearer"}}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn vietnam_numbers_are_unambiguous_and_normalized() {
        for raw in ["0901234567", "+84 90 123 4567", "901234567"] {
            assert_eq!(vietnam_phone(raw).unwrap(), "+84901234567");
        }
        for raw in ["+1901234567", "090abc4567", "123", "+840901234567"] {
            assert!(vietnam_phone(raw).is_err());
        }
    }
}
