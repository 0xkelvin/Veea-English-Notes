---
description: "Use when writing tests, adding test helpers, or setting up test fixtures. Covers unit test patterns, mocking, and assertion conventions."
applyTo: "**/*test*"
---
# Testing Conventions

## Structure

- Tests live in `#[cfg(test)] mod tests { use super::*; }` at the bottom of each source file.
- No separate `tests/` directory for unit tests.

## Naming

- Descriptive function names: `register_creates_active_user_with_user_role`, `expired_token_is_invalid`.
- Pattern: `action_expected_outcome` or `condition_expected_behavior`.

## Factories

- Use `make_*()` helper functions for test data:

```rust
fn make_user() -> User {
    User::register(
        Uuid::new_v4(),
        Email::new("test@example.com").unwrap(),
        PasswordHash::new("$argon2id$hash").unwrap(),
        Utc::now(),
    )
}
```

## Assertions

- Use `assert_eq!`, `assert!(...)`, `assert_matches!`.
- `claim` crate available: `claim::assert_ok!`, `claim::assert_err!`.
- Test both success and error paths.

## Async Tests

- Use `#[tokio::test]` for async tests (e.g. password hashing, JWT).
- Domain logic tests are sync `#[test]` — no runtime needed.

## Test Dependencies

```toml
tokio-test, reqwest (json), wiremock, fake (chrono, uuid, derive), claim
```

## Principles

- Domain tests need zero infrastructure (no DB, no Redis).
- Test aggregate invariants: creation, state transitions, error cases, event emission.
- Test value objects: valid construction, invalid rejection, edge cases.
