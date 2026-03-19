use axum::extract::{Path, Query, State};
use axum::response::IntoResponse;
use axum::Json;
use uuid::Uuid;
use validator::Validate;

use crate::application::identity::commands::change_user_role;
use crate::application::identity::dto::auth_dto::ChangeUserRoleRequest;
use crate::application::identity::queries::list_users;
use crate::bootstrap::app_state::AppState;
use crate::common::error::AppError;
use crate::common::pagination::PaginationParams;
use crate::common::result::AppResult;
use crate::interfaces::http::extractors::auth_user::AuthUser;
use crate::interfaces::http::response::ApiResponse;

/// GET /api/v1/admin/users
pub async fn list_users(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Query(pagination): Query<PaginationParams>,
) -> AppResult<axum::response::Response> {
    if !ctx.is_admin() {
        return Err(AppError::Forbidden);
    }

    let query = list_users::ListUsersQuery { pagination };
    let result = list_users::handle(query, state.user_repo.as_ref()).await?;

    Ok(ApiResponse::ok(result).into_response())
}

/// PUT /api/v1/admin/users/:id/role
pub async fn change_user_role(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Path(user_id): Path<Uuid>,
    Json(body): Json<ChangeUserRoleRequest>,
) -> AppResult<axum::response::Response> {
    if !ctx.is_admin() {
        return Err(AppError::Forbidden);
    }

    body.validate()
        .map_err(|e| AppError::Validation(e.to_string()))?;

    let cmd = change_user_role::ChangeUserRoleCommand {
        target_user_id: user_id,
        new_role: body.role,
        actor_id: ctx.user_id,
        actor_role: ctx.role,
    };

    let result = change_user_role::handle(
        cmd,
        state.user_repo.as_ref(),
        state.user_repo.as_ref(),
        state.outbox_repo.as_ref(),
        &state.db,
        &state.clock,
        &state.id_gen,
    )
    .await?;

    Ok(ApiResponse::ok(result).into_response())
}
