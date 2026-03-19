//! Application metrics helpers.
//!
//! For now we rely on the `tracing` + OpenTelemetry pipeline which exports
//! span-based metrics. This module provides a central place for future
//! custom counter/histogram registrations if needed.

use once_cell::sync::Lazy;
use std::sync::atomic::{AtomicU64, Ordering};

/// Simple in-process counters for key operations.
/// These are exported via the `/metrics` endpoint or OTLP.
pub struct AppMetrics {
    pub http_requests_total: AtomicU64,
    pub outbox_events_published: AtomicU64,
    pub outbox_events_failed: AtomicU64,
    pub auth_login_success: AtomicU64,
    pub auth_login_failure: AtomicU64,
}

pub static METRICS: Lazy<AppMetrics> = Lazy::new(|| AppMetrics {
    http_requests_total: AtomicU64::new(0),
    outbox_events_published: AtomicU64::new(0),
    outbox_events_failed: AtomicU64::new(0),
    auth_login_success: AtomicU64::new(0),
    auth_login_failure: AtomicU64::new(0),
});

impl AppMetrics {
    pub fn inc_http_requests(&self) {
        self.http_requests_total.fetch_add(1, Ordering::Relaxed);
    }

    pub fn inc_outbox_published(&self) {
        self.outbox_events_published.fetch_add(1, Ordering::Relaxed);
    }

    pub fn inc_outbox_failed(&self) {
        self.outbox_events_failed.fetch_add(1, Ordering::Relaxed);
    }

    pub fn inc_login_success(&self) {
        self.auth_login_success.fetch_add(1, Ordering::Relaxed);
    }

    pub fn inc_login_failure(&self) {
        self.auth_login_failure.fetch_add(1, Ordering::Relaxed);
    }

    /// Snapshot all metrics for reporting.
    pub fn snapshot(&self) -> MetricsSnapshot {
        MetricsSnapshot {
            http_requests_total: self.http_requests_total.load(Ordering::Relaxed),
            outbox_events_published: self.outbox_events_published.load(Ordering::Relaxed),
            outbox_events_failed: self.outbox_events_failed.load(Ordering::Relaxed),
            auth_login_success: self.auth_login_success.load(Ordering::Relaxed),
            auth_login_failure: self.auth_login_failure.load(Ordering::Relaxed),
        }
    }
}

#[derive(Debug, serde::Serialize)]
pub struct MetricsSnapshot {
    pub http_requests_total: u64,
    pub outbox_events_published: u64,
    pub outbox_events_failed: u64,
    pub auth_login_success: u64,
    pub auth_login_failure: u64,
}
