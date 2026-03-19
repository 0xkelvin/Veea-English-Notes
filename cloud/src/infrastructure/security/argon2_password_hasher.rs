use argon2::password_hash::SaltString;
use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};

use crate::application::identity::ports::password_hasher::PasswordHasher as PasswordHasherPort;

/// Argon2id password hasher — memory-hard, side-channel resistant.
pub struct Argon2PasswordHasher {
    argon2: Argon2<'static>,
}

impl Argon2PasswordHasher {
    pub fn new() -> Self {
        Self {
            argon2: Argon2::default(),
        }
    }
}

impl Default for Argon2PasswordHasher {
    fn default() -> Self {
        Self::new()
    }
}

impl PasswordHasherPort for Argon2PasswordHasher {
    async fn hash_password(&self, password: &str) -> Result<String, anyhow::Error> {
        let password = password.to_string();
        let argon2 = self.argon2.clone();

        // Argon2 hashing is CPU-intensive — run on blocking threadpool
        let hash = tokio::task::spawn_blocking(move || {
            let salt = SaltString::generate(&mut argon2::password_hash::rand_core::OsRng);
            argon2
                .hash_password(password.as_bytes(), &salt)
                .map(|h| h.to_string())
                .map_err(|e| anyhow::anyhow!("password hashing failed: {e}"))
        })
        .await??;

        Ok(hash)
    }

    async fn verify_password(&self, password: &str, hash: &str) -> Result<bool, anyhow::Error> {
        let password = password.to_string();
        let hash = hash.to_string();
        let argon2 = self.argon2.clone();

        let result = tokio::task::spawn_blocking(move || {
            let parsed = PasswordHash::new(&hash)
                .map_err(|e| anyhow::anyhow!("invalid PHC hash: {e}"))?;
            Ok::<bool, anyhow::Error>(argon2.verify_password(password.as_bytes(), &parsed).is_ok())
        })
        .await??;

        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn hash_and_verify_roundtrip() {
        let hasher = Argon2PasswordHasher::new();
        let pw = "SuperSecret123!";
        let hash = hasher.hash_password(pw).await.unwrap();
        assert!(hash.starts_with("$argon2"));
        assert!(hasher.verify_password(pw, &hash).await.unwrap());
    }

    #[tokio::test]
    async fn wrong_password_fails() {
        let hasher = Argon2PasswordHasher::new();
        let hash = hasher.hash_password("correct").await.unwrap();
        assert!(!hasher.verify_password("wrong", &hash).await.unwrap());
    }
}
