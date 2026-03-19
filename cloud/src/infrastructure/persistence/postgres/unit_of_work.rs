//! Re-exports for the Postgres transaction infrastructure.
//!
//! The actual transaction abstraction lives in `application::identity::transaction`.
//! This module provides convenience re-exports so infrastructure consumers can
//! import from a single location.

pub use crate::application::identity::transaction::{
    begin_tx, PgPool, PgTransaction, TransactionalOutboxRepository,
    TransactionalRefreshTokenRepository, TransactionalUserRepository,
};
