---
description: "Use when creating or modifying domain entities, value objects, domain events, repository ports, or domain services in src/domain/."
applyTo: "src/domain/**"
---
# Domain Layer Conventions

## Entities (Aggregate Roots)

- Collect domain events internally via `events: Vec<DomainEvent>`.
- Expose `take_events(&mut self) -> Vec<DomainEvent>` (uses `std::mem::take`).
- Factory method (e.g. `register()`) raises creation events.
- `reconstitute()` rebuilds from persistence — no events raised.
- All mutations enforce invariants and return `Result<(), DomainError>`.

```rust
pub fn change_role(&mut self, new_role: UserRole, changed_by: Uuid, now: DateTime<Utc>) -> Result<(), IdentityError> {
    // invariant checks
    self.role = new_role;
    self.updated_at = now;
    self.events.push(IdentityDomainEvent::UserRoleChanged(...));
    Ok(())
}
```

## Value Objects

- Validate in `new()` constructor, return `Result<Self, Error>`.
- Inner field is private, expose via `as_str()` or similar.
- Implement `From<String>` for trusted reconstruction from DB.
- `#[derive(Debug, Clone, PartialEq, Eq)]` at minimum.

## Repository Ports (Traits)

- Defined in `domain/<context>/repositories/`.
- All methods return `impl Future<Output = Result<T, anyhow::Error>> + Send`.
- Require `Send + Sync` bounds.
- Transactional variants accept `&mut PgTransaction<'a>` for multi-table atomicity.

## Domain Events

- Use `#[derive(Debug, Clone, Serialize)]` on event structs.
- Wrap in tagged enum: `#[serde(tag = "event_type", content = "payload")]`.
- Include `occurred_at: DateTime<Utc>` on every event.

## Domain Errors

- Use `#[derive(thiserror::Error, Debug, PartialEq, Eq)]`.
- One error enum per bounded context (e.g. `IdentityError`).
- Never expose infrastructure details in domain errors.
