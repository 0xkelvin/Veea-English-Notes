use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use english_notes_cloud::bootstrap::{
    app_state::AppState, config::AppConfig, database::init_database, logger::init_logger,
    messaging::init_messaging, redis::init_redis, telemetry::init_telemetry,
};
use english_notes_cloud::infrastructure::messaging::{DynEventBus, create_event_bus};
use english_notes_cloud::infrastructure::persistence::postgres::PgOutboxRepository;
use english_notes_cloud::interfaces::http::router::build_router;
use english_notes_cloud::workers::outbox_worker::OutboxWorker;
use tokio::signal;
use tokio::sync::watch;
use tracing::info;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Load .env in non-production environments
    let _ = dotenvy::dotenv();

    // Load configuration from environment
    let config = AppConfig::from_env()?;

    // Initialize logging (must come before any tracing calls)
    init_logger(&config.app.env);

    info!(
        name = %config.app.name,
        env = ?config.app.env,
        "Starting application"
    );

    // Initialize OpenTelemetry (hold guard for lifetime of app)
    let _telemetry_guard = init_telemetry(&config.observability)?;

    // Initialize infrastructure connections
    let db = init_database(&config.database).await?;
    let redis = init_redis(&config.redis).await?;
    let messaging = init_messaging(&config.messaging).await?;

    // Compose application state
    let state = AppState::new(config.clone(), db, redis, messaging);

    // ── Background workers ─────────────────────────────────────
    let (shutdown_tx, shutdown_rx) = watch::channel(false);

    // Outbox worker: polls pending events and publishes them
    let event_bus: Arc<DynEventBus> = Arc::new(create_event_bus(&state.messaging));
    let outbox_repo_worker = PgOutboxRepository::new(state.db.clone());
    let outbox_worker = OutboxWorker::new(
        outbox_repo_worker,
        event_bus,
        config.outbox.batch_size,
        config.outbox.max_retries,
        Duration::from_millis(config.outbox.poll_interval_ms),
        shutdown_rx,
    );
    let outbox_handle = tokio::spawn(outbox_worker.run());

    // Build HTTP router
    let app = build_router(state);

    // Bind and serve
    let addr = SocketAddr::from(([0, 0, 0, 0], config.app.port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    info!(%addr, "HTTP server listening");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    // Signal background workers to stop
    let _ = shutdown_tx.send(true);
    let _ = outbox_handle.await;

    info!("Application shut down gracefully");
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("Failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("Failed to install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => info!("Received Ctrl+C, starting graceful shutdown"),
        _ = terminate => info!("Received SIGTERM, starting graceful shutdown"),
    }
}
