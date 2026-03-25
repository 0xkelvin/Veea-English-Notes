# English Notes Backend

A production-grade Rust backend microservice template built with DDD, Clean Architecture, Hexagonal Architecture, CQRS, and the Transactional Outbox pattern.

## Architecture

```
src/
├── domain/           # Entities, value objects, domain events, repository ports
├── application/      # Use cases (commands & queries), DTOs, application services
├── infrastructure/   # PostgreSQL, Redis, NATS/Kafka, security, observability
├── interfaces/       # HTTP handlers, middleware, extractors, router
├── workers/          # Outbox poller, message consumer
├── bootstrap/        # Configuration, DI, database/Redis/messaging init
└── common/           # Shared types (errors, pagination, auth context)
```

### Key Patterns

| Pattern | Implementation |
|---|---|
| **Domain-Driven Design** | Aggregates, value objects, domain events in `domain/` |
| **Hexagonal Architecture** | Ports (traits) in domain, adapters in infrastructure |
| **CQRS** | Separate command/query handlers in `application/` |
| **Transactional Outbox** | Events written in same DB transaction, polled by `OutboxWorker` |
| **Idempotent Consumer** | Inbox table deduplication for NATS/Kafka messages |
| **HTTP Idempotency** | Client idempotency keys with cached responses |

## Tech Stack

- **Language**: Rust (edition 2024)
- **HTTP**: Axum 0.8 + Tower middleware
- **Database**: PostgreSQL 17 via SQLx 0.8
- **Cache**: Redis 7 (rate limiting, idempotency, sessions)
- **Messaging**: NATS (default) or Kafka (feature flag)
- **Auth**: Argon2id password hashing + JWT (access + refresh tokens)
- **Observability**: tracing + OpenTelemetry (OTLP/gRPC export)

## Getting Started

### Prerequisites

- Rust 1.88+
- Docker & Docker Compose
- (Optional) `cargo-sqlx` for migration management

### Quick Start

```bash
# Clone and configure
cp .env.example .env

# Start infrastructure (Postgres, Redis, NATS)
make docker-up

# Run the application (migrations run automatically on startup)
make dev
```

The server starts at `http://localhost:8386`.

### Useful Commands

```bash
make help          # Show all available targets
make check         # Run format check + clippy + tests
make test          # Run the test suite
make clippy        # Run linter
make fmt           # Format code
make docker-up     # Start Postgres, Redis, NATS
make docker-down   # Stop services
make docker-clean  # Stop and remove volumes
make migrate       # Run migrations manually
```

## API Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `GET` | `/health/live` | No | Liveness probe |
| `GET` | `/health/ready` | No | Readiness probe (checks DB & Redis) |
| `POST` | `/api/v1/auth/register` | No | Register a new user |
| `POST` | `/api/v1/auth/login` | No | Login (returns access + refresh tokens) |
| `POST` | `/api/v1/auth/refresh` | No | Refresh access token |
| `POST` | `/api/v1/auth/logout` | Yes | Revoke refresh token |
| `GET` | `/api/v1/users/me` | Yes | Get current user profile |
| `GET` | `/api/v1/admin/users` | Admin | List all users (paginated) |
| `PUT` | `/api/v1/admin/users/:id/role` | Admin | Change a user's role |
| `GET` | `/api/v1/openapi.json` | No | OpenAPI 3.0 specification |

## Environment Variables

See [.env.example](.env.example) for all available configuration options with defaults.

### Required in Production

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | PostgreSQL connection string |
| `REDIS_URL` | Redis connection string |
| `JWT_SECRET` | Minimum 32-character secret for JWT signing |

## Feature Flags

| Feature | Default | Description |
|---------|---------|-------------|
| `nats` | Yes | NATS messaging backend |
| `kafka` | No | Kafka messaging backend (enables `rdkafka`) |

```bash
# Build with Kafka support
cargo build --features kafka --no-default-features
```

## Docker

### Build & Run

```bash
# Build the image
docker compose build app

# Start everything
docker compose up -d

# View logs
docker compose logs -f app
```

### Services

| Service | Port | Description |
|---------|------|-------------|
| `app` | 8386 | Application server |
| `postgres` | 5432 | PostgreSQL 17 |
| `redis` | 6379 | Redis 7 |
| `nats` | 4222 / 8222 | NATS with JetStream + monitoring |

## Database Migrations

Migrations are in `migrations/` and run automatically on startup via SQLx.

```bash
# Run manually
make migrate

# Create a new migration
make migrate-add name=add_notes_table
```

### Tables

| Table | Purpose |
|-------|---------|
| `users` | User accounts (email, password hash, role, status) |
| `refresh_tokens` | JWT refresh token hashes with expiry |
| `outbox_events` | Transactional outbox for domain event publishing |
| `inbox_messages` | Idempotent consumer deduplication |
| `idempotency_records` | HTTP request idempotency cache |

## Testing

```bash
# Run all tests
make test

# Run with output
cargo test -- --nocapture

# Run specific test
cargo test test_name
```

## CI/CD

GitHub Actions workflow in `.github/workflows/ci.yml`:

1. **Check & Lint**: formatting (`cargo fmt --check`) + clippy
2. **Test**: Full test suite against PostgreSQL and Redis services

## Project Structure

```
├── Cargo.toml              # Dependencies and feature flags
├── Dockerfile              # Multi-stage production build
├── docker-compose.yml      # Local development stack
├── Makefile                # Developer shortcuts
├── .env.example            # Environment variable template
├── .github/workflows/      # CI configuration
├── migrations/             # SQL migration files
└── src/
    ├── main.rs             # Entry point, bootstrap, graceful shutdown
    ├── lib.rs              # Library root (re-exports all modules)
    ├── bootstrap/          # Init: config, database, redis, messaging, telemetry
    ├── common/             # Auth context, errors, pagination, correlation IDs
    ├── domain/identity/    # User aggregate, value objects, events, ports
    ├── application/identity/ # Commands, queries, DTOs, transactions
    ├── infrastructure/
    │   ├── persistence/    # PostgreSQL repositories
    │   ├── cache/          # Redis cache service
    │   ├── messaging/      # NATS/Kafka, outbox dispatcher
    │   ├── security/       # Argon2, JWT implementation
    │   └── observability/  # Health checks, metrics, tracing
    ├── interfaces/http/    # Router, handlers, middleware, extractors
    └── workers/            # Outbox worker, consumer worker
```

## License

MIT
