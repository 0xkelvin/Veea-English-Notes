---
description: "Use when implementing Postgres repositories, Redis cache, messaging adapters, security services, or persistence models in src/infrastructure/."
applyTo: "src/infrastructure/**"
---
# Infrastructure Layer Conventions

## Postgres Repositories

- Implement domain repository traits (ports).
- Use `sqlx::query_as!` or `sqlx::query!` for compile-time checked queries.
- Map between `*Row` (FromRow) structs and domain entities via `into_domain()` or `From<Row>`.
- Transactional methods accept `&mut sqlx::Transaction<'_, Postgres>`.

```rust
pub struct PgUserRepository { pool: PgPool }

impl UserRepository for PgUserRepository {
    async fn find_by_id(&self, id: Uuid) -> Result<Option<User>, anyhow::Error> {
        let row = sqlx::query_as::<_, UserRow>("SELECT * FROM users WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await?;
        row.map(|r| r.into_domain()).transpose()
    }
}
```

## Persistence Models (`models.rs`)

- `#[derive(Debug, FromRow)]` structs mirror DB columns exactly.
- Conversion to domain: `into_domain()` method (can fail for validation).
- Conversion from domain: `From<DomainEntity>` impl.

## Messaging (NATS / Kafka)

- Use `DynEventBus` enum dispatch — not `dyn EventBus` (async incompatible).
- Guard Kafka variants with `#[cfg(feature = "kafka")]`.
- Topic derivation: `{aggregate_type}.{event_type}` via `topics::derive_topic()`.

## Security

- `Argon2PasswordHasher`: CPU-heavy ops on `spawn_blocking`.
- `JwtServiceImpl`: issues + validates tokens, maps claims to `AuthContext`.

## Error Handling

- Use `anyhow::Error` with `.context("descriptive message")` for all infra errors.
- Never return domain errors from infrastructure — only `anyhow::Error`.
