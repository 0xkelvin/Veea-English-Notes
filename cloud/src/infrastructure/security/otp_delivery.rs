use crate::common::{error::AppError, result::AppResult};
use secrecy::{ExposeSecret, SecretString};
use serde::Deserialize;
use std::future::Future;
use std::time::Duration;

pub trait OtpDelivery: Send + Sync {
    fn available(&self) -> bool;
    fn send(&self, phone: &str) -> impl Future<Output = AppResult<String>> + Send;
    fn check(
        &self,
        sid: &str,
        phone: &str,
        code: &str,
    ) -> impl Future<Output = AppResult<bool>> + Send;
}

/// This adapter is inactive until Nin supplies the existing delivery credentials.
/// No development code or OTP value is logged or returned to a client.
pub struct TwilioVerify {
    client: reqwest::Client,
    account: String,
    token: SecretString,
    service: String,
    base: String,
}

#[derive(Deserialize)]
struct Verification {
    sid: String,
    status: String,
    to: String,
}

impl TwilioVerify {
    pub fn from_env() -> Self {
        Self {
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .expect("HTTP client"),
            account: std::env::var("OTP_TWILIO_ACCOUNT_SID").unwrap_or_default(),
            token: SecretString::from(std::env::var("OTP_TWILIO_AUTH_TOKEN").unwrap_or_default()),
            service: std::env::var("OTP_TWILIO_VERIFY_SERVICE_SID").unwrap_or_default(),
            base: "https://verify.twilio.com/v2".into(),
        }
    }
    fn endpoint(&self, resource: &str) -> String {
        format!("{}/Services/{}/{}", self.base, self.service, resource)
    }
}

impl OtpDelivery for TwilioVerify {
    fn available(&self) -> bool {
        !self.account.is_empty()
            && !self.token.expose_secret().is_empty()
            && !self.service.is_empty()
    }
    async fn send(&self, phone: &str) -> AppResult<String> {
        if !self.available() {
            return Err(AppError::Unavailable(
                "Phone sign-in is not available yet. Your words remain saved on this device."
                    .into(),
            ));
        }
        let response = self
            .client
            .post(self.endpoint("Verifications"))
            .basic_auth(&self.account, Some(self.token.expose_secret()))
            .form(&[("To", phone), ("Channel", "sms"), ("Locale", "vi")])
            .send()
            .await
            .map_err(|_| {
                AppError::Unavailable("Could not send a code. Please try again later.".into())
            })?;
        if !response.status().is_success() {
            return Err(AppError::Unavailable(
                "Could not send a code. Please try again later.".into(),
            ));
        }
        let data: Verification = response.json().await.map_err(|_| {
            AppError::Unavailable("Could not send a code. Please try again later.".into())
        })?;
        if data.status != "pending" || data.to != phone || !data.sid.starts_with("VE") {
            return Err(AppError::Unavailable(
                "Could not send a code. Please try again later.".into(),
            ));
        }
        Ok(data.sid)
    }
    async fn check(&self, sid: &str, phone: &str, code: &str) -> AppResult<bool> {
        if !self.available() {
            return Err(AppError::Unavailable(
                "Phone sign-in is not available yet.".into(),
            ));
        }
        let response = self
            .client
            .post(self.endpoint("VerificationCheck"))
            .basic_auth(&self.account, Some(self.token.expose_secret()))
            .form(&[("VerificationSid", sid), ("Code", code)])
            .send()
            .await
            .map_err(|_| {
                AppError::Unavailable("Could not verify the code. Please try again.".into())
            })?;
        if response.status().as_u16() == 404 || response.status().as_u16() == 400 {
            return Ok(false);
        }
        if !response.status().is_success() {
            return Err(AppError::Unavailable(
                "Could not verify the code. Please try again.".into(),
            ));
        }
        let data: Verification = response.json().await.map_err(|_| {
            AppError::Unavailable("Could not verify the code. Please try again.".into())
        })?;
        Ok(data.status == "approved" && data.to == phone && data.sid == sid)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::{
        Mock, MockServer, ResponseTemplate,
        matchers::{body_string_contains, method, path},
    };
    #[tokio::test]
    async fn only_approved_matching_phone_and_challenge_are_accepted() {
        let server = MockServer::start().await;
        let mut delivery = TwilioVerify::from_env();
        delivery.account = "ACtest".into();
        delivery.token = SecretString::from("secret".to_string());
        delivery.service = "VAtest".into();
        delivery.base = server.uri();
        Mock::given(method("POST"))
            .and(path("/Services/VAtest/VerificationCheck"))
            .and(body_string_contains("VerificationSid=VEtest"))
            .respond_with(ResponseTemplate::new(200).set_body_json(
                serde_json::json!({"sid":"VEtest","to":"+84901234567","status":"pending"}),
            ))
            .mount(&server)
            .await;
        assert!(
            !delivery
                .check("VEtest", "+84901234567", "123456")
                .await
                .unwrap()
        );
        server.reset().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(200).set_body_json(
                serde_json::json!({"sid":"VEtest","to":"+84901234567","status":"approved"}),
            ))
            .mount(&server)
            .await;
        assert!(
            delivery
                .check("VEtest", "+84901234567", "123456")
                .await
                .unwrap()
        );
        assert!(
            !delivery
                .check("VEtest", "+84909999999", "123456")
                .await
                .unwrap()
        );
        assert!(
            !delivery
                .check("VEother", "+84901234567", "123456")
                .await
                .unwrap()
        );
    }
}
