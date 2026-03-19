use std::future::Future;

/// Port for password hashing and verification.
///
/// Uses a slow, memory-hard algorithm (e.g. Argon2) in the infrastructure layer.
/// The application layer never sees the algorithm choice.
pub trait PasswordHasher: Send + Sync {
    /// Hash a plaintext password and return the PHC-formatted hash string.
    fn hash_password(&self, password: &str) -> impl Future<Output = Result<String, anyhow::Error>> + Send;

    /// Verify a plaintext password against a stored hash.
    /// Returns `true` if the password matches.
    fn verify_password(
        &self,
        password: &str,
        hash: &str,
    ) -> impl Future<Output = Result<bool, anyhow::Error>> + Send;
}
