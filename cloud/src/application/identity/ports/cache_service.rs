use std::future::Future;
use std::time::Duration;

/// Port for cache operations (backed by Redis or similar).
pub trait CacheService: Send + Sync {
    /// Get a value by key. Returns `None` if not found or expired.
    fn get(&self, key: &str) -> impl Future<Output = Result<Option<String>, anyhow::Error>> + Send;

    /// Set a value with a TTL.
    fn set(
        &self,
        key: &str,
        value: &str,
        ttl: Duration,
    ) -> impl Future<Output = Result<(), anyhow::Error>> + Send;

    /// Delete a key.
    fn delete(&self, key: &str) -> impl Future<Output = Result<(), anyhow::Error>> + Send;

    /// Check if a key exists.
    fn exists(&self, key: &str) -> impl Future<Output = Result<bool, anyhow::Error>> + Send;

    /// Increment a counter (for rate limiting). Returns the new value.
    fn increment(
        &self,
        key: &str,
        ttl: Duration,
    ) -> impl Future<Output = Result<u64, anyhow::Error>> + Send;
}
