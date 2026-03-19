---
description: "Use when creating or modifying HTTP handlers, middleware, extractors, or routes in src/interfaces/http/."
applyTo: "src/interfaces/http/**"
---
# HTTP Interface Conventions

## Handlers

- One file per resource group (e.g. `auth_handler.rs`, `user_handler.rs`).
- Accept `State(state): State<AppState>` and typed extractors.
- Return `AppResult<Json<ApiResponse<T>>>` (never raw `impl IntoResponse`).
- Use `#[instrument(skip_all)]` for tracing.

```rust
pub async fn register(
    State(state): State<AppState>,
    meta: RequestMeta,
    Json(body): Json<RegisterRequest>,
) -> AppResult<Json<ApiResponse<AuthResponse>>> {
    // validate, call application layer, return response
}
```

## Response Envelope

- All API responses wrapped in `ApiResponse<T>`:
  - `ApiResponse::ok(data)` → 200
  - `ApiResponse::created(data)` → 201

## Extractors

- `AuthUser` — extracts JWT claims from `Authorization: Bearer` header.
- `RequestMeta` — extracts `RequestId` + `CorrelationId` from extensions.
- `IdempotencyKeyExtractor` — extracts `Idempotency-Key` header.

## Middleware Stack (ordered)

request_id → correlation_id → logging → compression → timeout → panic_recovery → rate_limit → routes (some protected by jwt_auth → role_guard → idempotency)

## Router

- Public routes: health checks, auth (register/login/refresh), OpenAPI spec.
- Protected routes: nested under auth middleware.
- Admin routes: additional `require_admin` role guard.
- Versioned under `/api/v1/`.

## Error Mapping

- `AppError` variants map to HTTP status codes.
- Internal errors: log full context, return generic 500 to client.
- Validation errors: 400 with descriptive message.
