use tracing_subscriber::{EnvFilter, fmt, layer::SubscriberExt, util::SubscriberInitExt};

use super::config::AppEnvironment;

/// Initialize the logging subscriber.
///
/// In production, emits structured JSON logs for machine consumption.
/// In development, emits human-readable formatted logs for developer ergonomics.
pub fn init_logger(env: &AppEnvironment) {
    let env_filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| {
        EnvFilter::new("info,english_notes_cloud=debug,sqlx=warn,tower_http=debug")
    });

    let registry = tracing_subscriber::registry().with(env_filter);

    match env {
        AppEnvironment::Production | AppEnvironment::Staging => {
            let json_layer = fmt::layer()
                .json()
                .with_target(true)
                .with_thread_ids(true)
                .with_file(false)
                .with_line_number(false)
                .flatten_event(true);
            registry.with(json_layer).init();
        }
        AppEnvironment::Development => {
            let fmt_layer = fmt::layer()
                .with_target(true)
                .with_thread_ids(false)
                .with_file(true)
                .with_line_number(true);
            registry.with(fmt_layer).init();
        }
    }
}
