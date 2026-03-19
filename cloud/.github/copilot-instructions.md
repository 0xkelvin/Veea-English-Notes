# English Notes Backend — Copilot Instructions

## Architecture

This is a **Rust microservice** using DDD + Clean Architecture + Hexagonal + CQRS + Transactional Outbox.

```
domain/           → Aggregates, value objects, domain events, repository ports (traits)
application/      → Command/query handlers, DTOs, application ports, transaction orchestration
infrastructure/   → Postgres repos, Redis cache, NATS/Kafka messaging, Argon2/JWT security
interfaces/http/  → Axum handlers, middleware, extractors, router
workers/          → Background workers (outbox dispatcher, message consumer)
bootstrap/        → Config, AppState composition root, service initialization
common/           → AppError, AppResult<T>, shared traits, correlation/request IDs
```

## Core Rules

- **Rust edition 2024** — use `impl Future` in traits (RPITIT), let-chains, etc.
- **Dependency direction**: domain → ← application → ← infrastructure/interfaces. Domain has ZERO external crate dependencies beyond std, uuid, chrono, serde, thiserror.
- **Ports & Adapters**: domain defines traits (`UserRepository`, `PasswordHasher`), infrastructure implements them. Application depends on trait bounds, never concrete types.
- **No `dyn Trait` for async traits**: use enum dispatch (`DynEventBus`) or `impl Trait` bounds. Our async traits return `impl Future<Output = ...> + Send`.
- **Value objects validate in constructors**: `Email::new()` returns `Result`. Once created, they are immutable and trusted.
- **Domain events collected inside aggregates**: `user.take_events()` drains after persistence. Events + entity persisted atomically via `sqlx::Transaction`.
- **Feature flags**: `nats` (default), `kafka` (optional via `dep:rdkafka`). Use `#[cfg(feature = "kafka")]` for conditional compilation.

## Error Handling

- **Domain/Application**: `thiserror` enums for typed errors, `anyhow::Error` for infrastructure context.
- **HTTP surface**: `AppError` enum implements `IntoResponse`. Internal details are logged, never exposed to clients.
- **Pattern**: `AppResult<T> = Result<T, AppError>` as the return type for handlers.

## Naming & Style

- Snake_case for modules, files, functions. PascalCase for types/traits.
- Tests: inline `#[cfg(test)] mod tests` at bottom of each file.
- Tracing: `#[instrument(skip_all, fields(...))]` on command/query handlers.
- All public repository methods are `async` returning `Result<T, anyhow::Error>`.

## Build Commands

```
make check    # fmt-check + clippy + test (the full CI gate)
make dev      # cargo run
make test     # cargo test --all-features
make clippy   # cargo clippy --all-targets --all-features -- -D warnings
```
