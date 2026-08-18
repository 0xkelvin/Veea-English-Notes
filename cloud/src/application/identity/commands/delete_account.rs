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

#[derive(Debug)]
pub struct DeleteAccountCommand {
    pub user_id: Uuid,
    /// The caller's current password, re-entered to confirm.
    pub password: String,
}

/// Permanently delete the caller's own account.
///
/// The password is required again even though the request is already
/// authenticated: an access token lasts fifteen minutes and may have been
/// lifted from an unlocked phone, and this is the one action with no way back.
///
/// Everything the account owns — vocabulary, refresh tokens — is removed by
/// `ON DELETE CASCADE`, so there is exactly one statement that can leave
/// orphans and it is the one that deletes the user row.
// Dependencies are passed explicitly rather than through a service locator,
// which is the trade-off this architecture already makes elsewhere.
#[allow(clippy::too_many_arguments)]
#[instrument(skip_all, fields(user_id = %cmd.user_id))]
pub async fn handle(
    cmd: DeleteAccountCommand,
    user_repo: &impl UserRepository,
    user_repo_tx: &impl TransactionalUserRepository,
    outbox_repo_tx: &impl TransactionalOutboxRepository,
    refresh_repo: &impl RefreshTokenRepository,
    pool: &PgPool,
    hasher: &impl PasswordHasher,
    clock: &impl Clock,
    id_gen: &impl IdGenerator,
) -> AppResult<()> {
    let mut user = user_repo
        .find_by_id(cmd.user_id)
        .await?
        .ok_or_else(|| AppError::NotFound("user not found".to_string()))?;

    let valid = hasher
        .verify_password(&cmd.password, user.password_hash.as_str())
        .await?;
    if !valid {
        // Not Unauthorized: the session is fine, the typed password was not.
        return Err(AppError::InvalidPassword);
    }

    let now = clock.now();

    // Revoke sessions before the row goes, so any token still in flight stops
    // working even if the delete below fails.
    refresh_repo.revoke_all_for_user(user.id, now).await?;

    // The identifier is captured into the event here, while the row still
    // exists; consumers see this after there is nothing left to look up.
    user.mark_deleted(now);
    let events = user.take_events();

    let mut tx = begin_tx(pool).await?;
    for event in &events {
        let outbox = build_outbox_event(event, id_gen, now)?;
        outbox_repo_tx.insert_tx(&mut tx, &outbox).await?;
    }
    user_repo_tx.delete_tx(&mut tx, user.id).await?;
    tx.commit().await?;

    tracing::info!(user_id = %cmd.user_id, "account deleted");
    Ok(())
}
