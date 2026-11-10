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
    request_bound_challenge(pool, delivery, phone, purpose, user_id, ip, None).await
}

/// `proof` binds a `change_new` challenge to the consumed `change_current`
/// challenge that authorised it and to the account phone that proof was for.
async fn request_bound_challenge(
    pool: &PgPool,
    delivery: &impl OtpDelivery,
    phone: &str,
    purpose: &str,
    user_id: Option<Uuid>,
    ip: &str,
    proof: Option<(Uuid, &str)>,
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
    sqlx::query("INSERT INTO otp_challenges(id,phone,ip_hash,purpose,user_id,expires_at,proof_challenge_id,expected_phone) VALUES($1,$2,$3,$4,$5,now() + INTERVAL '10 minutes',$6,$7)")
        .bind(id).bind(&phone).bind(ip_hash).bind(purpose).bind(user_id)
        .bind(proof.map(|p| p.0)).bind(proof.map(|p| p.1)).execute(&mut *tx).await?;
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
    let (access, raw) = mint_session_tx(
        &mut tx,
        &user,
        refresh,
        jwt,
        ids,
        now,
        access_secs,
        refresh_secs,
    )
    .await?;
    tx.commit().await?;
    Ok(
        serde_json::json!({"user_id": user.id, "identifier": phone, "auth_method":"phone_otp", "tokens": {"access_token":access,"refresh_token":raw,"expires_in":access_secs,"token_type":"Bearer"}}),
    )
}

/// Inserts a refresh token and signs an access token inside the caller's
/// transaction, so a session is only issued if the surrounding change commits.
#[allow(clippy::too_many_arguments)]
async fn mint_session_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    user: &User,
    refresh: &impl TransactionalRefreshTokenRepository,
    jwt: &impl JwtService,
    ids: &impl IdGenerator,
    now: chrono::DateTime<chrono::Utc>,
    access_secs: i64,
    refresh_secs: i64,
) -> AppResult<(String, String)> {
    let raw = generate_refresh_token();
    refresh
        .insert_tx(
            tx,
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
    Ok((access, raw))
}

// ── Verified phone-number change ───────────────────────────────────────────
//
// 1. `request_current_phone_code`: code to the account's *current* phone.
// 2. `verify_current_phone`: consumes it and returns a proof id (the consumed
//    challenge). A proof is fresh for `PROOF_FRESH_SECS`, belongs to one
//    account and one phone number, and can complete at most one change.
// 3. `request_new_phone_code`: with a fresh proof, sends a code to the new
//    phone. The challenge records the proof and the phone it expects the
//    account still to have. Resending re-uses the same proof.
// 4. `confirm_phone_change`: consumes the new-phone code, then in a single
//    transaction re-checks the proof and expected phone under locks, moves the
//    number, revokes every refresh token and issues one replacement session.
// The account UUID never changes, so notebooks and sync cursors stay valid.

/// How long a verified current-phone proof can be used to start or finish a change.
pub const PROOF_FRESH_SECS: i64 = 900;

const STALE_PROOF: &str = "Your confirmation of your current number expired, was already used, or your number changed in another session. Please start again.";

#[derive(Serialize, Debug)]
pub struct PhoneChangeProof {
    pub proof_id: Uuid,
    pub expires_in: i64,
}

fn stale_proof() -> AppError {
    AppError::NotFound(STALE_PROOF.into())
}

async fn current_phone_for_change(pool: &PgPool, user_id: Uuid) -> AppResult<String> {
    let row: Option<(Option<String>, String, String)> =
        sqlx::query_as("SELECT phone, auth_method, status FROM users WHERE id = $1")
            .bind(user_id)
            .fetch_optional(pool)
            .await?;
    let (phone, method, status) = row.ok_or(AppError::Unauthorized)?;
    if status != "active" {
        return Err(AppError::Unauthorized);
    }
    match phone {
        Some(phone) if method == "phone_otp" => Ok(phone),
        _ => Err(AppError::Validation(
            "Changing the phone number is available only for accounts that sign in with a phone code.".into(),
        )),
    }
}

pub async fn request_current_phone_code(
    pool: &PgPool,
    delivery: &impl OtpDelivery,
    user_id: Uuid,
    ip: &str,
) -> AppResult<ChallengeResponse> {
    let phone = current_phone_for_change(pool, user_id).await?;
    request_challenge(pool, delivery, &phone, "change_current", Some(user_id), ip).await
}

pub async fn verify_current_phone(
    pool: &PgPool,
    delivery: &impl OtpDelivery,
    user_id: Uuid,
    challenge_id: Uuid,
    code: &str,
) -> AppResult<PhoneChangeProof> {
    let proven = consume_challenge(
        pool,
        delivery,
        challenge_id,
        code,
        "change_current",
        Some(user_id),
    )
    .await?;
    // The code went to the number the account had when it was sent; if the
    // number has moved since, this proof is for a phone the account no longer has.
    if current_phone_for_change(pool, user_id).await? != proven {
        return Err(stale_proof());
    }
    Ok(PhoneChangeProof {
        proof_id: challenge_id,
        expires_in: PROOF_FRESH_SECS,
    })
}

pub async fn request_new_phone_code(
    pool: &PgPool,
    delivery: &impl OtpDelivery,
    user_id: Uuid,
    proof_id: Uuid,
    new_phone: &str,
    ip: &str,
) -> AppResult<ChallengeResponse> {
    let new_phone = vietnam_phone(new_phone)?;
    let proven: Option<(String,)> = sqlx::query_as(
        "SELECT p.phone FROM otp_challenges p JOIN users u ON u.id = p.user_id \
         WHERE p.id = $1 AND p.purpose = 'change_current' AND p.user_id = $2 \
           AND p.consumed_at IS NOT NULL AND p.proof_spent_at IS NULL \
           AND p.consumed_at > now() - make_interval(secs => $3) \
           AND u.phone = p.phone AND u.status = 'active'",
    )
    .bind(proof_id)
    .bind(user_id)
    .bind(PROOF_FRESH_SECS as f64)
    .fetch_optional(pool)
    .await?;
    let (current,) = proven.ok_or_else(stale_proof)?;
    if current == new_phone {
        return Err(AppError::Validation(
            "That is already your account's phone number. Enter a different number.".into(),
        ));
    }
    request_bound_challenge(
        pool,
        delivery,
        &new_phone,
        "change_new",
        Some(user_id),
        ip,
        Some((proof_id, current.as_str())),
    )
    .await
}

#[allow(clippy::too_many_arguments)]
pub async fn confirm_phone_change(
    pool: &PgPool,
    delivery: &impl OtpDelivery,
    user_id: Uuid,
    challenge_id: Uuid,
    code: &str,
    users: &(impl UserRepository + TransactionalUserRepository),
    refresh: &impl TransactionalRefreshTokenRepository,
    outbox: &impl TransactionalOutboxRepository,
    jwt: &impl JwtService,
    clock: &impl Clock,
    ids: &impl IdGenerator,
    access_secs: i64,
    refresh_secs: i64,
) -> AppResult<serde_json::Value> {
    let new_phone = consume_challenge(
        pool,
        delivery,
        challenge_id,
        code,
        "change_new",
        Some(user_id),
    )
    .await?;
    let (proof_id, expected): (Uuid, String) = sqlx::query_as(
        "SELECT proof_challenge_id, expected_phone FROM otp_challenges \
         WHERE id = $1 AND purpose = 'change_new' AND user_id = $2 \
           AND proof_challenge_id IS NOT NULL AND expected_phone IS NOT NULL",
    )
    .bind(challenge_id)
    .bind(user_id)
    .fetch_optional(pool)
    .await?
    .ok_or_else(stale_proof)?;
    if new_phone == expected {
        return Err(AppError::Validation(
            "That is already your account's phone number. Enter a different number.".into(),
        ));
    }

    let now = clock.now();
    let mut tx = pool.begin().await?;
    // Same lock keys as sign-in, taken in a fixed order so two accounts swapping
    // numbers cannot deadlock and a concurrent sign-up of the new number waits.
    let mut keys = [expected.clone(), new_phone.clone()];
    keys.sort();
    for key in &keys {
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
            .bind(key)
            .execute(&mut *tx)
            .await?;
    }
    let locked: Option<(Option<String>, String)> =
        sqlx::query_as("SELECT phone, status FROM users WHERE id = $1 FOR UPDATE")
            .bind(user_id)
            .fetch_optional(&mut *tx)
            .await?;
    let (current, status) = locked.ok_or(AppError::Unauthorized)?;
    if status != "active" {
        return Err(AppError::Unauthorized);
    }
    if current.as_deref() != Some(expected.as_str()) {
        return Err(stale_proof());
    }
    let spent = sqlx::query(
        "UPDATE otp_challenges SET proof_spent_at = now() \
         WHERE id = $1 AND purpose = 'change_current' AND user_id = $2 AND phone = $3 \
           AND consumed_at IS NOT NULL AND proof_spent_at IS NULL \
           AND consumed_at > now() - make_interval(secs => $4)",
    )
    .bind(proof_id)
    .bind(user_id)
    .bind(&expected)
    .bind(PROOF_FRESH_SECS as f64)
    .execute(&mut *tx)
    .await?;
    if spent.rows_affected() != 1 {
        return Err(stale_proof());
    }
    let holder: Option<(Uuid,)> =
        sqlx::query_as("SELECT id FROM users WHERE phone = $1 FOR UPDATE")
            .bind(&new_phone)
            .fetch_optional(&mut *tx)
            .await?;
    if holder.is_some() {
        // Disclosed only after the caller proved they control the new number.
        return Err(number_in_use());
    }

    let mut user = users
        .find_by_id(user_id)
        .await?
        .ok_or(AppError::Unauthorized)?;
    user.change_identifier(
        Identifier::parse(&new_phone).map_err(|e| AppError::Validation(e.to_string()))?,
        now,
    )
    .map_err(|e| AppError::Validation(e.to_string()))?;
    users
        .update_tx(&mut tx, &user)
        .await
        .map_err(|e| match e.downcast_ref::<sqlx::Error>() {
            Some(sqlx::Error::Database(db)) if db.code().as_deref() == Some("23505") => {
                number_in_use()
            }
            _ => AppError::Internal(e),
        })?;
    sqlx::query("UPDATE users SET phone_verified_at = $1 WHERE id = $2")
        .bind(now)
        .bind(user_id)
        .execute(&mut *tx)
        .await?;
    for event in user.take_events() {
        outbox
            .insert_tx(&mut tx, &build_outbox_event(&event, ids, now)?)
            .await?;
    }
    // Every other device must re-verify with the new number.
    let revoked = sqlx::query(
        "UPDATE refresh_tokens SET revoked_at = $1 WHERE user_id = $2 AND revoked_at IS NULL",
    )
    .bind(now)
    .bind(user_id)
    .execute(&mut *tx)
    .await?;
    let (access, raw) = mint_session_tx(
        &mut tx,
        &user,
        refresh,
        jwt,
        ids,
        now,
        access_secs,
        refresh_secs,
    )
    .await?;
    tx.commit().await?;
    Ok(serde_json::json!({
        "user_id": user.id,
        "identifier": new_phone,
        "auth_method": "phone_otp",
        "revoked_sessions": revoked.rows_affected(),
        "tokens": {"access_token": access, "refresh_token": raw, "expires_in": access_secs, "token_type": "Bearer"}
    }))
}

fn number_in_use() -> AppError {
    AppError::Conflict(
        "That number is already used by another Veea account. Enter a different number.".into(),
    )
}

// ── Verified account deletion with a recoverable outcome ───────────────────

/// How long a deletion receipt answers "was my account deleted?".
pub const DELETION_RECEIPT_DAYS: i64 = 30;

fn receipt_hash(challenge_id: Uuid) -> String {
    hex::encode(Sha256::digest(
        format!("deletion-receipt:{challenge_id}").as_bytes(),
    ))
}

/// Deletes the account after a fresh account-bound code and, in the same
/// transaction, records a receipt so a client whose response was lost can
/// later prove the deletion happened rather than guessing from a 401.
pub async fn delete_verified_account(
    pool: &PgPool,
    delivery: &impl OtpDelivery,
    user_id: Uuid,
    challenge_id: Uuid,
    code: &str,
    users: &(impl UserRepository + TransactionalUserRepository),
    outbox: &impl TransactionalOutboxRepository,
    clock: &impl Clock,
    ids: &impl IdGenerator,
) -> AppResult<()> {
    let phone =
        consume_challenge(pool, delivery, challenge_id, code, "delete", Some(user_id)).await?;
    let now = clock.now();
    let mut tx = pool.begin().await?;
    let locked: Option<(Option<String>,)> =
        sqlx::query_as("SELECT phone FROM users WHERE id = $1 FOR UPDATE")
            .bind(user_id)
            .fetch_optional(&mut *tx)
            .await?;
    let (current,) = locked.ok_or(AppError::Unauthorized)?;
    if current.as_deref() != Some(phone.as_str()) {
        return Err(AppError::Forbidden);
    }
    let mut user = users
        .find_by_id(user_id)
        .await?
        .ok_or(AppError::Unauthorized)?;
    user.mark_deleted(now);
    for event in user.take_events() {
        outbox
            .insert_tx(&mut tx, &build_outbox_event(&event, ids, now)?)
            .await?;
    }
    sqlx::query(
        "INSERT INTO account_deletion_receipts(user_id, receipt_hash, deleted_at) VALUES($1,$2,$3) \
         ON CONFLICT (user_id) DO UPDATE SET receipt_hash = EXCLUDED.receipt_hash, deleted_at = EXCLUDED.deleted_at",
    )
    .bind(user_id)
    .bind(receipt_hash(challenge_id))
    .bind(now)
    .execute(&mut *tx)
    .await?;
    users.delete_tx(&mut tx, user_id).await?;
    sqlx::query("DELETE FROM account_deletion_receipts WHERE deleted_at < now() - make_interval(days => $1)")
        .bind(DELETION_RECEIPT_DAYS as i32)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(())
}

/// True only when this exact deletion challenge deleted this account. False
/// means "not proven": the deletion did not happen through this challenge, or
/// the receipt is older than the retention window.
pub async fn deletion_confirmed(
    pool: &PgPool,
    user_id: Uuid,
    challenge_id: Uuid,
) -> AppResult<bool> {
    let row: Option<(i32,)> = sqlx::query_as(
        "SELECT 1 FROM account_deletion_receipts WHERE user_id = $1 AND receipt_hash = $2 \
         AND deleted_at > now() - make_interval(days => $3)",
    )
    .bind(user_id)
    .bind(receipt_hash(challenge_id))
    .bind(DELETION_RECEIPT_DAYS as i32)
    .fetch_optional(pool)
    .await?;
    Ok(row.is_some())
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
