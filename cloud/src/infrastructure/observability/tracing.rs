//! Additional tracing utilities for request-scoped context injection.
//!
//! The core subscriber initialization lives in `bootstrap::telemetry`.
//! This module provides per-request span enrichment helpers.

use tracing::Span;

/// Enrich the current span with request metadata.
pub fn enrich_span_with_request(
    span: &Span,
    method: &str,
    uri: &str,
    request_id: &str,
) {
    span.record("http.method", method);
    span.record("http.url", uri);
    span.record("request_id", request_id);
}

/// Enrich the current span with authenticated user info.
pub fn enrich_span_with_user(span: &Span, user_id: &str, role: &str) {
    span.record("user.id", user_id);
    span.record("user.role", role);
}
