use tracing::instrument;
use uuid::Uuid;

use crate::application::identity::commands::support::build_outbox_event;
use crate::application::identity::dto::user_dto::UserProfileResponse;
use crate::application::identity::ports::clock::Clock;
use crate::application::identity::ports::id_generator::IdGenerator;
use crate::application::identity::ports::password_hasher::PasswordHasher;
use crate::application::identity::transaction::{
    PgPool, TransactionalOutboxRepository, TransactionalUserRepository, begin_tx,
};
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::domain::identity::repositories::user_repository::UserRepository;
use crate::domain::identity::value_objects::identifier::Identifier;

#[derive(Debug)]
pub struct ChangeIdentifierCommand {
    pub user_id: Uuid,
    /// The new email address or phone number.
    pub identifier: String,
    /// The caller's current password, re-entered to confirm.
    pub password: String,
}

/// Change the email address or phone number on the caller's own account.
///
/// The password is required again because moving an account's identifier is
/// how a hijacked session would take it over permanently.
///
/// Only the matching kind is replaced: setting a phone on an email account
/// keeps the email, so the account stays reachable both ways rather than
/// silently losing its original identifier.
#[instrument(skip_all, fields(user_id = %cmd.user_id, identifier_kind = tracing::field::Empty))]
pub async fn handle(
    cmd: ChangeIdentifierCommand,
    user_repo: &impl UserRepository,
    user_repo_tx: &impl TransactionalUserRepository,
    outbox_repo_tx: &impl TransactionalOutboxRepository,
    pool: &PgPool,
    hasher: &impl PasswordHasher,
    clock: &impl Clock,
    id_gen: &impl IdGenerator,
) -> AppResult<UserProfileResponse> {
    let identifier =
        Identifier::parse(&cmd.identifier).map_err(|e| AppError::Validation(e.to_string()))?;
    tracing::Span::current().record("identifier_kind", identifier.kind());

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

    // Taken by somebody else? The unique index is the real guard; this turns
    // the usual case into a clear 409. Finding *this* user is fine — it means
    // they re-submitted what they already have, which the aggregate no-ops.
    if let Some(existing) = user_repo.find_by_identifier(&identifier).await?
        && existing.id != user.id
    {
        return Err(AppError::Conflict(
            "that email or phone number is already registered".to_string(),
        ));
    }

    let now = clock.now();
    user.change_identifier(identifier, now)
        .map_err(|e| AppError::Validation(e.to_string()))?;

    let events = user.take_events();

    let mut tx = begin_tx(pool).await?;
    user_repo_tx.update_tx(&mut tx, &user).await?;
    for event in &events {
        let outbox = build_outbox_event(event, id_gen, now)?;
        outbox_repo_tx.insert_tx(&mut tx, &outbox).await?;
    }
    tx.commit().await?;

    Ok(UserProfileResponse::from(&user))
}
