use chrono::{DateTime, Utc};

/// Return the current UTC timestamp.
///
/// Centralized so that time can be mocked in tests via the `Clock` port.
pub fn now() -> DateTime<Utc> {
    Utc::now()
}
