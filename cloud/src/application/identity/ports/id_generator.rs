use uuid::Uuid;

/// Port for generating unique identifiers.
///
/// Allows deterministic testing by injecting a fake generator.
pub trait IdGenerator: Send + Sync {
    fn new_id(&self) -> Uuid;
}

/// Production ID generator using UUIDv4.
#[derive(Debug, Clone, Copy)]
pub struct UuidGenerator;

impl IdGenerator for UuidGenerator {
    fn new_id(&self) -> Uuid {
        Uuid::new_v4()
    }
}
