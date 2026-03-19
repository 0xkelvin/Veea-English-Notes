use axum::extract::Request;
use tower_http::trace::{DefaultOnResponse, TraceLayer};
use tracing::Level;

/// Build the request/response tracing layer.
pub fn trace_layer() -> TraceLayer<tower_http::classify::SharedClassifier<tower_http::classify::ServerErrorsAsFailures>, impl Fn(&Request<axum::body::Body>) -> tracing::Span + Clone> {
    TraceLayer::new_for_http().make_span_with(|request: &Request<axum::body::Body>| {
        let request_id = request
            .extensions()
            .get::<crate::common::request_id::RequestId>()
            .map(|r| r.to_string())
            .unwrap_or_default();

        tracing::info_span!(
            "http_request",
            method = %request.method(),
            uri = %request.uri(),
            request_id = %request_id,
        )
    })
    .on_response(DefaultOnResponse::new().level(Level::INFO))
}
