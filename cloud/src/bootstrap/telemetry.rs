use opentelemetry::trace::TracerProvider;
use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::{runtime, trace as sdktrace, Resource};
use opentelemetry::KeyValue;
use tracing::info;

use super::config::ObservabilityConfig;

/// Initialize OpenTelemetry tracing pipeline.
///
/// When enabled, exports traces via OTLP/gRPC to the configured collector endpoint.
/// Returns a guard that must be held for the lifetime of the application
/// to ensure proper flushing on shutdown.
pub struct TelemetryGuard {
    provider: Option<sdktrace::TracerProvider>,
}

impl Drop for TelemetryGuard {
    fn drop(&mut self) {
        if let Some(provider) = self.provider.take()
            && let Err(err) = provider.shutdown()
        {
            eprintln!("Failed to shut down tracer provider: {err:?}");
        }
    }
}

pub fn init_telemetry(config: &ObservabilityConfig) -> Result<TelemetryGuard, anyhow::Error> {
    if !config.enabled {
        info!("OpenTelemetry tracing is disabled");
        return Ok(TelemetryGuard { provider: None });
    }

    let resource = Resource::new(vec![
        KeyValue::new(
            opentelemetry_semantic_conventions::resource::SERVICE_NAME,
            config.service_name.clone(),
        ),
    ]);

    let exporter = opentelemetry_otlp::SpanExporter::builder()
        .with_tonic()
        .with_endpoint(&config.otlp_endpoint)
        .build()?;

    let provider = sdktrace::TracerProvider::builder()
        .with_resource(resource)
        .with_batch_exporter(exporter, runtime::Tokio)
        .build();

    let _tracer = provider.tracer(config.service_name.clone());

    // Note: In the full bootstrap, the OTel tracing layer is composed
    // with the subscriber in logger.rs. Here we store the provider
    // for graceful shutdown.

    info!("OpenTelemetry tracing initialized, exporting to {}", config.otlp_endpoint);

    Ok(TelemetryGuard {
        provider: Some(provider),
    })
}
