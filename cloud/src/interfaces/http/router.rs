use axum::routing::{get, post, put};
use axum::{middleware, Router};
use tower_http::limit::RequestBodyLimitLayer;

use crate::bootstrap::app_state::AppState;

use super::handlers::{admin_handler, auth_handler, health_handler, user_handler};
use super::middleware as mw;
use super::openapi;

/// Build the complete Axum router with all routes and middleware.
pub fn build_router(state: AppState) -> Router {
    let api_v1 = Router::new()
        // ── Public auth routes ──────────────────────────────
        .route("/auth/register", post(auth_handler::register))
        .route("/auth/login", post(auth_handler::login))
        .route("/auth/refresh", post(auth_handler::refresh))
        // ── Protected auth routes ───────────────────────────
        .route("/auth/logout", post(auth_handler::logout))
        // ── Protected user routes ───────────────────────────
        .route("/users/me", get(user_handler::get_my_profile))
        // ── Admin routes ────────────────────────────────────
        .route("/admin/users", get(admin_handler::list_users))
        .route(
            "/admin/users/{id}/role",
            put(admin_handler::change_user_role),
        )
        // ── Idempotency (opt-in via header) ────────────────
        .layer(middleware::from_fn_with_state(
            state.clone(),
            mw::idempotency::idempotency_middleware,
        ))
        // ── Rate limiting ──────────────────────────────────
        .layer(middleware::from_fn_with_state(
            state.clone(),
            mw::rate_limit::rate_limit_middleware,
        ));

    Router::new()
        // ── Health probes (no middleware) ───────────────────
        .route("/health/live", get(health_handler::liveness))
        .route("/health/ready", get(health_handler::readiness))
        // ── OpenAPI spec ───────────────────────────────────
        .route("/api/openapi.json", get(openapi::openapi_spec))
        // ── API v1 ─────────────────────────────────────────
        .nest("/api/v1", api_v1)
        // ── Global middleware (outermost → innermost) ──────
        .layer(mw::compression::compression_layer())
        .layer(mw::logging::trace_layer())
        .layer(middleware::from_fn(
            mw::correlation_id::correlation_id_middleware,
        ))
        .layer(middleware::from_fn(
            mw::request_id::request_id_middleware,
        ))
        .layer(mw::timeout::timeout_layer(
            state.config.app.request_timeout_secs,
        ))
        .layer(RequestBodyLimitLayer::new(
            state.config.app.body_limit_bytes,
        ))
        .layer(mw::panic_recovery::catch_panic_layer())
        .with_state(state)
}
