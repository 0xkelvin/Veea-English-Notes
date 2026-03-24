use std::time::Duration;

use redis::aio::ConnectionManager;
use redis::AsyncCommands;

use crate::application::identity::ports::cache_service::CacheService;

/// Redis-backed cache service implementation.
pub struct RedisCacheService {
    conn: ConnectionManager,
}

impl RedisCacheService {
    pub fn new(conn: ConnectionManager) -> Self {
        Self { conn }
    }
}

impl CacheService for RedisCacheService {
    async fn get(&self, key: &str) -> Result<Option<String>, anyhow::Error> {
        let mut conn = self.conn.clone();
        let value: Option<String> = conn.get(key).await?;
        Ok(value)
    }

    async fn set(&self, key: &str, value: &str, ttl: Duration) -> Result<(), anyhow::Error> {
        let mut conn = self.conn.clone();
        let _: () = conn.set_ex(key, value, ttl.as_secs()).await?;
        Ok(())
    }

    async fn delete(&self, key: &str) -> Result<(), anyhow::Error> {
        let mut conn = self.conn.clone();
        let _: () = conn.del(key).await?;
        Ok(())
    }

    async fn exists(&self, key: &str) -> Result<bool, anyhow::Error> {
        let mut conn = self.conn.clone();
        let exists: bool = conn.exists(key).await?;
        Ok(exists)
    }

    async fn increment(&self, key: &str, ttl: Duration) -> Result<u64, anyhow::Error> {
        let mut conn = self.conn.clone();
        let val: u64 = redis::cmd("INCR")
            .arg(key)
            .query_async(&mut conn)
            .await?;
        // Set TTL only on first increment (when value is 1)
        if val == 1 {
            let _: () = conn.expire(key, ttl.as_secs() as i64).await?;
        }
        Ok(val)
    }
}
