use chrono::{DateTime, Utc};

/// Port for obtaining the current time.
///
/// Allows deterministic testing by injecting a fake clock.
pub trait Clock: Send + Sync {
    fn now(&self) -> DateTime<Utc>;
}

/// Production clock using the system time.
#[derive(Debug, Clone, Copy)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> DateTime<Utc> {
        Utc::now()
    }
}
