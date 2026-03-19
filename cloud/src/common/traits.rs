/// Marker trait for domain entities.
///
/// Kept minimal — domain entities don't need framework-imposed constraints.
pub trait Entity {
    type Id;
    fn id(&self) -> &Self::Id;
}
