use tracing::instrument;
use uuid::Uuid;

use crate::application::identity::commands::support::build_outbox_event;
use crate::application::identity::ports::clock::Clock;
use crate::application::identity::ports::id_generator::IdGenerator;
use crate::application::identity::ports::password_hasher::PasswordHasher;
use crate::application::identity::transaction::{
    PgPool, TransactionalOutboxRepository, TransactionalUserRepository, begin_tx,
};
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::domain::identity::repositories::refresh_token_repository::RefreshTokenRepository;
use crate::domain::identity::repositories::user_repository::UserRepository;
use crate::domain::identity::value_objects::password_hash::PasswordHash;

#[derive(Debug)]
pub struct ChangePasswordCommand {
    pub user_id: Uuid,
    pub current_password: String,
    pub new_password: String,
}

/// Change the caller's own password.
///
/// Every refresh token is revoked afterwards, including the caller's own. A
/// password change is usually a response to suspecting someone else has the
/// account, and leaving their session alive would defeat the point; the client
/// signs in again with the new password.
// Dependencies are passed explicitly rather than through a service locator,
// which is the trade-off this architecture already makes elsewhere.
#[allow(clippy::too_many_arguments)]
#[instrument(skip_all, fields(user_id = %cmd.user_id))]
pub async fn handle(
    cmd: ChangePasswordCommand,
    user_repo: &impl UserRepository,
    user_repo_tx: &impl TransactionalUserRepository,
    outbox_repo_tx: &impl TransactionalOutboxRepository,
    refresh_repo: &impl RefreshTokenRepository,
    pool: &PgPool,
    hasher: &impl PasswordHasher,
    clock: &impl Clock,
    id_gen: &impl IdGenerator,
) -> AppResult<()> {
    if cmd.new_password.len() < 8 || cmd.new_password.len() > 128 {
        return Err(AppError::Validation(
            "password must be between 8 and 128 characters".to_string(),
        ));
    }

    let mut user = user_repo
        .find_by_id(cmd.user_id)
        .await?
        .ok_or_else(|| AppError::NotFound("user not found".to_string()))?;

    let valid = hasher
        .verify_password(&cmd.current_password, user.password_hash.as_str())
        .await?;
    if !valid {
        // Not Unauthorized: the session is fine, the typed password was not.
        return Err(AppError::InvalidPassword);
    }

    if cmd.current_password == cmd.new_password {
        return Err(AppError::Validation(
            "the new password must be different from the current one".to_string(),
        ));
    }

    let now = clock.now();
    let new_hash = hasher.hash_password(&cmd.new_password).await?;
    let new_hash = PasswordHash::new(new_hash).map_err(|e| AppError::Validation(e.to_string()))?;

    user.change_password(new_hash, now);
    let events = user.take_events();

    let mut tx = begin_tx(pool).await?;
    user_repo_tx.update_tx(&mut tx, &user).await?;
    for event in &events {
        let outbox = build_outbox_event(event, id_gen, now)?;
        outbox_repo_tx.insert_tx(&mut tx, &outbox).await?;
    }
    tx.commit().await?;

    // After the commit: a revocation that ran first and then hit a failed
    // commit would sign the user out without having changed anything.
    refresh_repo.revoke_all_for_user(user.id, now).await?;

    Ok(())
}
