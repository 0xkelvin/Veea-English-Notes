use anyhow::Context;
use chrono::{DateTime, Utc};
use jsonwebtoken::{DecodingKey, EncodingKey, Header, Validation};
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::application::identity::ports::jwt_service::{
    AccessTokenClaims, JwtService, ValidatedClaims,
};

/// JWT service backed by `jsonwebtoken` with HMAC-SHA256.
pub struct JwtServiceImpl {
    encoding_key: EncodingKey,
    decoding_key: DecodingKey,
    issuer: String,
    audience: String,
}

impl JwtServiceImpl {
    pub fn new(secret: &SecretString, issuer: String, audience: String) -> Self {
        let secret_bytes = secret.expose_secret().as_bytes().to_vec();
        Self {
            encoding_key: EncodingKey::from_secret(&secret_bytes),
            decoding_key: DecodingKey::from_secret(&secret_bytes),
            issuer,
            audience,
        }
    }
}

/// Internal JWT claims structure matching the jsonwebtoken crate.
#[derive(Debug, Serialize, Deserialize)]
struct JwtClaims {
    sub: String,
    email: String,
    role: String,
    jti: String,
    iss: String,
    aud: String,
    iat: i64,
    exp: i64,
}

impl JwtService for JwtServiceImpl {
    fn create_access_token(&self, claims: &AccessTokenClaims) -> Result<String, anyhow::Error> {
        let jwt_claims = JwtClaims {
            sub: claims.sub.to_string(),
            email: claims.email.clone(),
            role: claims.role.clone(),
            jti: claims.jti.to_string(),
            iss: self.issuer.clone(),
            aud: self.audience.clone(),
            iat: claims.iat.timestamp(),
            exp: claims.exp.timestamp(),
        };

        let token = jsonwebtoken::encode(&Header::default(), &jwt_claims, &self.encoding_key)
            .context("failed to encode JWT")?;

        Ok(token)
    }

    fn validate_access_token(&self, token: &str) -> Result<ValidatedClaims, anyhow::Error> {
        let mut validation = Validation::default();
        validation.set_issuer(&[&self.issuer]);
        validation.set_audience(&[&self.audience]);
        validation.set_required_spec_claims(&["exp", "sub", "iss", "aud"]);

        let data = jsonwebtoken::decode::<JwtClaims>(token, &self.decoding_key, &validation)
            .context("JWT validation failed")?;

        let claims = data.claims;

        Ok(ValidatedClaims {
            sub: Uuid::parse_str(&claims.sub).context("invalid sub UUID")?,
            email: claims.email,
            role: claims.role,
            jti: Uuid::parse_str(&claims.jti).context("invalid jti UUID")?,
            exp: DateTime::<Utc>::from_timestamp(claims.exp, 0)
                .ok_or_else(|| anyhow::anyhow!("invalid exp timestamp"))?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_service() -> JwtServiceImpl {
        JwtServiceImpl::new(
            &SecretString::from("test-secret-key-at-least-32-bytes-long!"),
            "test-issuer".to_string(),
            "test-audience".to_string(),
        )
    }

    #[test]
    fn create_and_validate_roundtrip() {
        let svc = make_service();
        let now = Utc::now();
        let claims = AccessTokenClaims {
            sub: Uuid::new_v4(),
            email: "user@example.com".to_string(),
            role: "user".to_string(),
            jti: Uuid::new_v4(),
            iat: now,
            exp: now + chrono::Duration::seconds(900),
        };

        let token = svc.create_access_token(&claims).unwrap();
        let validated = svc.validate_access_token(&token).unwrap();

        assert_eq!(validated.sub, claims.sub);
        assert_eq!(validated.email, "user@example.com");
        assert_eq!(validated.role, "user");
        assert_eq!(validated.jti, claims.jti);
    }

    #[test]
    fn expired_token_fails() {
        let svc = make_service();
        let now = Utc::now();
        let claims = AccessTokenClaims {
            sub: Uuid::new_v4(),
            email: "user@example.com".to_string(),
            role: "user".to_string(),
            jti: Uuid::new_v4(),
            iat: now - chrono::Duration::seconds(3600),
            exp: now - chrono::Duration::seconds(1800),
        };

        let token = svc.create_access_token(&claims).unwrap();
        assert!(svc.validate_access_token(&token).is_err());
    }

    #[test]
    fn tampered_token_fails() {
        let svc = make_service();
        let now = Utc::now();
        let claims = AccessTokenClaims {
            sub: Uuid::new_v4(),
            email: "user@example.com".to_string(),
            role: "user".to_string(),
            jti: Uuid::new_v4(),
            iat: now,
            exp: now + chrono::Duration::seconds(900),
        };

        let mut token = svc.create_access_token(&claims).unwrap();
        token.push('x'); // tamper
        assert!(svc.validate_access_token(&token).is_err());
    }
}
