//! Application-wide constants.
//!
//! Naming conventions, header names, and other shared literals.

pub const API_V1_PREFIX: &str = "/api/v1";
pub const HEALTH_PREFIX: &str = "/health";

/// Redis key prefix to namespace all keys for this service.
pub const REDIS_KEY_PREFIX: &str = "eng-notes";

/// Default maximum request body size in bytes (1 MiB).
pub const DEFAULT_BODY_LIMIT: usize = 1_048_576;

/// Idempotency key HTTP header name.
pub const IDEMPOTENCY_KEY_HEADER: &str = "idempotency-key";

/// Cache TTL defaults (seconds).
pub const CACHE_TTL_SHORT: u64 = 60;
pub const CACHE_TTL_MEDIUM: u64 = 300;
pub const CACHE_TTL_LONG: u64 = 3600;
