use tracing::instrument;
use uuid::Uuid;

use crate::application::identity::dto::user_dto::UserProfileResponse;
use crate::application::identity::ports::clock::Clock;
use crate::application::identity::ports::id_generator::IdGenerator;
use crate::application::identity::transaction::{
    begin_tx, PgPool, TransactionalOutboxRepository, TransactionalUserRepository,
};
use crate::common::error::AppError;
use crate::common::result::AppResult;
use crate::domain::identity::events::IdentityDomainEvent;
use crate::domain::identity::repositories::outbox_repository::{OutboxEvent, OutboxStatus};
use crate::domain::identity::repositories::user_repository::UserRepository;
use crate::domain::identity::services::identity_policy::IdentityPolicy;
use crate::domain::identity::value_objects::user_role::UserRole;

#[derive(Debug)]
pub struct ChangeUserRoleCommand {
    pub target_user_id: Uuid,
    pub new_role: String,
    pub actor_id: Uuid,
    pub actor_role: String,
}

/// Change a user's role (admin only).
///
/// 1. Parse and validate the new role
/// 2. Apply domain policy (authorization)
/// 3. Load the target user
/// 4. Apply the role change (aggregate enforces invariants)
/// 5. Persist user + outbox event in one transaction
#[instrument(skip_all, fields(target_user_id = %cmd.target_user_id, new_role = %cmd.new_role))]
pub async fn handle(
    cmd: ChangeUserRoleCommand,
    user_repo: &impl UserRepository,
    user_repo_tx: &impl TransactionalUserRepository,
    outbox_repo_tx: &impl TransactionalOutboxRepository,
    pool: &PgPool,
    clock: &impl Clock,
    id_gen: &impl IdGenerator,
) -> AppResult<UserProfileResponse> {
    // 1. Parse new role
    let new_role = UserRole::from_str_checked(&cmd.new_role)
        .map_err(|e| AppError::Validation(e.to_string()))?;
    let actor_role = UserRole::from_str_checked(&cmd.actor_role)
        .map_err(|e| AppError::Validation(e.to_string()))?;

    // 2. Policy check
    IdentityPolicy::can_change_role(cmd.actor_id, &actor_role, cmd.target_user_id, &new_role)
        .map_err(|_| AppError::Forbidden)?;

    // 3. Load target user
    let mut user = user_repo
        .find_by_id(cmd.target_user_id)
        .await?
        .ok_or_else(|| AppError::NotFound("user not found".to_string()))?;

    // 4. Apply change
    let now = clock.now();
    user.change_role(new_role, cmd.actor_id, now)
        .map_err(|e| AppError::Validation(e.to_string()))?;

    // 5. Collect events and persist
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

fn build_outbox_event(
    event: &IdentityDomainEvent,
    id_gen: &impl IdGenerator,
    now: chrono::DateTime<chrono::Utc>,
) -> Result<OutboxEvent, anyhow::Error> {
    Ok(OutboxEvent {
        id: id_gen.new_id(),
        aggregate_type: event.aggregate_type().to_string(),
        aggregate_id: event.aggregate_id(),
        event_type: event.event_type().to_string(),
        payload: serde_json::to_value(event)?,
        metadata: serde_json::json!({}),
        status: OutboxStatus::Pending,
        occurred_at: now,
        published_at: None,
        retry_count: 0,
    })
}
