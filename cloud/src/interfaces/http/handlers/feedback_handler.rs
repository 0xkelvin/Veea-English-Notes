use crate::application::identity::ports::cache_service::CacheService;
use crate::interfaces::http::{extractors::auth_user::AuthUser, response::ApiResponse};
use crate::{
    bootstrap::app_state::AppState,
    common::{error::AppError, result::AppResult},
    infrastructure::security::otp_delivery::OtpDelivery,
};
use axum::{
    Json,
    extract::{Path, State},
    http::{HeaderMap, header},
    response::IntoResponse,
};
use base64::Engine;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

#[derive(Deserialize)]
pub struct SubmitFeedback {
    id: Uuid,
    kind: String,
    message: String,
    contact: Option<String>,
    #[serde(default)]
    diagnostics: Value,
    screenshot_base64: Option<String>,
}
fn owner(headers: &HeaderMap) -> AppResult<String> {
    let key = headers
        .get("x-feedback-key")
        .and_then(|v| v.to_str().ok())
        .ok_or(AppError::Unauthorized)?;
    if key.len() < 32
        || key.len() > 100
        || !key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err(AppError::Unauthorized);
    }
    Ok(hex::encode(Sha256::digest(key.as_bytes())))
}
fn validate(body: &SubmitFeedback) -> AppResult<Option<Vec<u8>>> {
    if !["bug", "feature", "other"].contains(&body.kind.as_str())
        || !(5..=4000).contains(&body.message.trim().chars().count())
    {
        return Err(AppError::Validation(
            "Choose a feedback type and describe it in 5–4000 characters.".into(),
        ));
    }
    if body
        .contact
        .as_ref()
        .is_some_and(|c| c.chars().count() > 254)
    {
        return Err(AppError::Validation("Contact details are too long.".into()));
    }
    if !body.diagnostics.is_null()
        && (!body.diagnostics.is_object()
            || body.diagnostics.to_string().len() > 3000
            || body.diagnostics.as_object().is_some_and(|m| {
                m.keys()
                    .any(|k| !["app_version", "platform", "os", "screen"].contains(&k.as_str()))
            }))
    {
        return Err(AppError::Validation("Invalid diagnostics.".into()));
    }
    match &body.screenshot_base64 {
        None => Ok(None),
        Some(encoded) => {
            if encoded.len() > 700_000 {
                return Err(AppError::Validation(
                    "Please choose a smaller screenshot.".into(),
                ));
            }
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(encoded)
                .map_err(|_| AppError::Validation("Invalid screenshot.".into()))?;
            if bytes.len() > 524_288
                || !(bytes.starts_with(b"\xff\xd8\xff") || bytes.starts_with(b"\x89PNG\r\n\x1a\n"))
            {
                return Err(AppError::Validation(
                    "Please attach a JPG or PNG under 512 KB.".into(),
                ));
            }
            Ok(Some(bytes))
        }
    }
}
pub async fn submit(
    State(state): State<AppState>,
    ip: Option<axum::Extension<axum::extract::ConnectInfo<std::net::SocketAddr>>>,
    headers: HeaderMap,
    Json(body): Json<SubmitFeedback>,
) -> AppResult<axum::response::Response> {
    let owner = owner(&headers)?;
    let screenshot = validate(&body)?;
    let ip = ip
        .map(|i| i.0.0.ip().to_string())
        .unwrap_or_else(|| "unknown".into());
    let rate_key = format!("feedback:ip:{}", hex::encode(Sha256::digest(ip.as_bytes())));
    let count = state
        .cache_service
        .increment(&rate_key, std::time::Duration::from_secs(3600))
        .await
        .map_err(|_| {
            AppError::Unavailable("Could not submit feedback yet. Please try again later.".into())
        })?;
    if count > 50 {
        return Err(AppError::RateLimitExceeded);
    }
    let mut tx = state.db.begin().await?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))")
        .bind(&owner)
        .execute(&mut *tx)
        .await?;
    let existing: Option<(String,)> =
        sqlx::query_as("SELECT owner_hash FROM feedback_reports WHERE id = $1")
            .bind(body.id)
            .fetch_optional(&mut *tx)
            .await?;
    if let Some((previous,)) = existing {
        if previous != owner {
            return Err(AppError::Conflict(
                "Could not submit this report. Please create a new report.".into(),
            ));
        }
    } else {
        let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM feedback_reports WHERE owner_hash = $1 AND created_at > now() - INTERVAL '1 hour'").bind(&owner).fetch_one(&mut *tx).await?;
        if count.0 >= 10 {
            return Err(AppError::RateLimitExceeded);
        }
        sqlx::query("INSERT INTO feedback_reports(id,owner_hash,kind,message,contact,diagnostics,screenshot) VALUES($1,$2,$3,$4,$5,$6,$7)")
            .bind(body.id).bind(&owner).bind(&body.kind).bind(body.message.trim()).bind(&body.contact).bind(if body.diagnostics.is_null() { json!({}) } else { body.diagnostics }).bind(screenshot).execute(&mut *tx).await?;
    }
    let row: (String, Option<String>) = sqlx::query_as(
        "SELECT status,team_reply FROM feedback_reports WHERE id = $1 AND owner_hash = $2",
    )
    .bind(body.id)
    .bind(owner)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(ApiResponse::ok(json!({"id":body.id,"status":row.0,"team_reply":row.1})).into_response())
}
pub async fn mine(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> AppResult<axum::response::Response> {
    let rows: Vec<(Uuid,String,Option<String>)> = sqlx::query_as("SELECT id,status,team_reply FROM feedback_reports WHERE owner_hash = $1 ORDER BY created_at DESC LIMIT 100").bind(owner(&headers)?).fetch_all(&state.db).await?;
    Ok(ApiResponse::ok(json!({"reports": rows.into_iter().map(|(id,status,reply)| json!({"id":id,"status":status,"team_reply":reply})).collect::<Vec<_>>()})).into_response())
}
pub async fn admin_list(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
) -> AppResult<axum::response::Response> {
    if !ctx.is_admin() {
        return Err(AppError::Forbidden);
    }
    let rows: Vec<(Value,)> = sqlx::query_as("SELECT jsonb_build_object('id',id,'kind',kind,'message',message,'contact',contact,'diagnostics',diagnostics,'has_screenshot',screenshot IS NOT NULL,'status',status,'team_reply',team_reply,'created_at',created_at,'updated_at',updated_at) FROM feedback_reports ORDER BY created_at DESC LIMIT 100").fetch_all(&state.db).await?;
    Ok(
        ApiResponse::ok(json!({"reports":rows.into_iter().map(|r| r.0).collect::<Vec<_>>()}))
            .into_response(),
    )
}
#[derive(Deserialize)]
pub struct UpdateFeedback {
    status: String,
    team_reply: Option<String>,
}
pub async fn admin_update(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdateFeedback>,
) -> AppResult<axum::response::Response> {
    if !ctx.is_admin() {
        return Err(AppError::Forbidden);
    }
    if !["received", "reviewing", "planned", "completed", "closed"].contains(&body.status.as_str())
        || body
            .team_reply
            .as_ref()
            .is_some_and(|r| r.chars().count() > 2000)
    {
        return Err(AppError::Validation(
            "Invalid feedback status or reply.".into(),
        ));
    }
    let result = sqlx::query("UPDATE feedback_reports SET status = $1, team_reply = $2, updated_at = now() WHERE id = $3").bind(&body.status).bind(body.team_reply).bind(id).execute(&state.db).await?;
    if result.rows_affected() == 0 {
        return Err(AppError::NotFound("Report not found".into()));
    }
    Ok(ApiResponse::ok(json!({"id":id,"status":body.status})).into_response())
}
pub async fn screenshot(
    State(state): State<AppState>,
    AuthUser(ctx): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<axum::response::Response> {
    if !ctx.is_admin() {
        return Err(AppError::Forbidden);
    }
    let row: Option<(Option<Vec<u8>>,)> =
        sqlx::query_as("SELECT screenshot FROM feedback_reports WHERE id = $1")
            .bind(id)
            .fetch_optional(&state.db)
            .await?;
    let bytes = row
        .and_then(|r| r.0)
        .ok_or_else(|| AppError::NotFound("Screenshot not found".into()))?;
    let mime = if bytes.starts_with(b"\x89PNG") {
        "image/png"
    } else {
        "image/jpeg"
    };
    Ok((
        [
            (header::CONTENT_TYPE, mime),
            (header::CACHE_CONTROL, "no-store"),
        ],
        bytes,
    )
        .into_response())
}
pub fn community_url() -> Option<String> {
    std::env::var("VEEA_ZALO_COMMUNITY_URL")
        .ok()
        .filter(|url| url.starts_with("https://zalo.me/g/") && !url.contains(['\r', '\n', ' ']))
}
pub async fn config(State(state): State<AppState>) -> impl IntoResponse {
    ApiResponse::ok(
        json!({"phone_otp_available":state.otp_delivery.available(),"zalo_community_url":community_url(),"sync_protocol_version":2}),
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reports_accept_only_bounded_explicit_data() {
        let mut report = SubmitFeedback {
            id: Uuid::new_v4(),
            kind: "feature".into(),
            message: "Please add desktop sync".into(),
            contact: None,
            diagnostics: json!({"platform":"ios"}),
            screenshot_base64: None,
        };
        assert!(validate(&report).is_ok());
        report.diagnostics = json!({"saved_words":["private"]});
        assert!(validate(&report).is_err());
        report.diagnostics = json!({});
        report.message = " ".into();
        assert!(validate(&report).is_err());
        report.message = "Helpful message".into();
        report.screenshot_base64 =
            Some(base64::engine::general_purpose::STANDARD.encode(b"<svg>bad</svg>"));
        assert!(validate(&report).is_err());
    }
}
