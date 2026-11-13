//! Regression test for N1: a cached `Idempotency-Key` response must never be
//! replayed to a caller who has not authenticated.
//!
//! Drives the real `build_router` with synthetic data. Run only against a
//! disposable local PostgreSQL and Redis:
//!
//! ```text
//! VEEA_TEST_DATABASE_URL=postgres://...@127.0.0.1:.../... \
//! VEEA_TEST_REDIS_URL=redis://127.0.0.1:... \
//!   cargo test --test idempotency_regression -- --ignored
//! ```
use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode},
};
use english_notes_cloud::{
    bootstrap::{
        app_state::AppState,
        config::{
            AppConfig, AppEnvironment, DatabaseConfig, JwtConfig, MessagingBackend,
            MessagingConfig, ObservabilityConfig, OutboxConfig, RateLimitConfig, RedisConfig,
            ServerConfig,
        },
        messaging::MessagingConnection,
    },
    interfaces::http::router::build_router,
};
use secrecy::SecretString;
use sqlx::{PgPool, postgres::PgPoolOptions};
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

const REPLAY_HEADER: &str = "x-idempotent-replay";

/// What one request returned, captured so assertions can run after cleanup.
struct Seen {
    status: StatusCode,
    replayed: bool,
    body: String,
}

fn config(database_url: &str, redis_url: &str) -> Arc<AppConfig> {
    Arc::new(AppConfig {
        app: ServerConfig {
            name: "n1-regression".into(),
            env: AppEnvironment::Development,
            host: "127.0.0.1".into(),
            port: 0,
            workers: 1,
            request_timeout_secs: 30,
            body_limit_bytes: 1_048_576,
        },
        database: DatabaseConfig {
            url: SecretString::from(database_url.to_string()),
            max_connections: 4,
            min_connections: 1,
            acquire_timeout_secs: 5,
            idle_timeout_secs: 30,
            max_lifetime_secs: 300,
        },
        redis: RedisConfig {
            url: SecretString::from(redis_url.to_string()),
            pool_size: 1,
        },
        jwt: JwtConfig {
            secret: SecretString::from("n1-regression-secret-for-local-tests-only-0123456789"),
            issuer: "n1-regression".into(),
            audience: "n1-regression".into(),
            access_token_expiry_secs: 900,
            refresh_token_expiry_secs: 3600,
        },
        messaging: MessagingConfig {
            backend: MessagingBackend::Nats,
            nats_url: String::new(),
            kafka_brokers: String::new(),
            kafka_group_id: String::new(),
            kafka_client_id: String::new(),
        },
        observability: ObservabilityConfig {
            otlp_endpoint: String::new(),
            service_name: "n1-regression".into(),
            enabled: false,
        },
        outbox: OutboxConfig {
            poll_interval_ms: 500,
            batch_size: 1,
            max_retries: 1,
        },
        // The router rate-limits by peer IP, and `oneshot` has none, so every
        // request shares one bucket. Keep it far above what this test sends.
        rate_limit: RateLimitConfig {
            requests_per_second: 10_000,
            burst: 10_000,
        },
    })
}

fn require_local(var: &str, markers: [&str; 2]) -> String {
    let url = std::env::var(var).unwrap_or_else(|_| panic!("Set {var} to a disposable local URL"));
    assert!(
        markers.iter().any(|m| url.contains(m)),
        "{var} must point at localhost"
    );
    url
}

async fn send(
    app: &Router,
    method: &str,
    path: &str,
    bearer: Option<&str>,
    key: Option<&str>,
    json: Option<serde_json::Value>,
) -> Seen {
    let mut builder = Request::builder().method(method).uri(path);
    if let Some(token) = bearer {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    if let Some(key) = key {
        builder = builder.header("idempotency-key", key);
    }
    let body = match json {
        Some(value) => {
            builder = builder.header("content-type", "application/json");
            Body::from(value.to_string())
        }
        None => Body::empty(),
    };
    let response = app
        .clone()
        .oneshot(builder.body(body).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let replayed = response.headers().contains_key(REPLAY_HEADER);
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .unwrap();
    Seen {
        status,
        replayed,
        body: String::from_utf8_lossy(&bytes).into_owned(),
    }
}

/// Everything the scenario observed, plus the synthetic email and key used.
struct Outcome {
    email: String,
    key: String,
    profile: Seen,
    anonymous_repeat: Seen,
    wrong_password_login: Seen,
}

async fn scenario(app: &Router) -> Outcome {
    let email = format!("n1-{}@example.com", Uuid::new_v4().simple());
    let password = "synthetic-Passw0rd-1";
    let key = format!("n1-key-{}", Uuid::new_v4());

    let registered = send(
        app,
        "POST",
        "/api/v1/auth/register",
        None,
        None,
        Some(serde_json::json!({ "identifier": email, "password": password })),
    )
    .await;
    assert_eq!(
        registered.status,
        StatusCode::CREATED,
        "setup failed: {}",
        registered.body
    );
    let parsed: serde_json::Value = serde_json::from_str(&registered.body).unwrap();
    let token = parsed["data"]["tokens"]["access_token"]
        .as_str()
        .unwrap()
        .to_string();

    let profile = send(
        app,
        "GET",
        "/api/v1/users/me",
        Some(&token),
        Some(&key),
        None,
    )
    .await;
    let anonymous_repeat = send(app, "GET", "/api/v1/users/me", None, Some(&key), None).await;
    let wrong_password_login = send(
        app,
        "POST",
        "/api/v1/auth/login",
        None,
        Some(&key),
        Some(serde_json::json!({ "identifier": email, "password": "wrong-Passw0rd-9" })),
    )
    .await;
    Outcome {
        email,
        key,
        profile,
        anonymous_repeat,
        wrong_password_login,
    }
}

/// Remove the cache entry an unfixed build would have written, so a failing
/// run leaves nothing behind in Redis.
async fn forget_key(redis_url: &str, key: &str) {
    let client = redis::Client::open(redis_url).unwrap();
    let mut conn = client.get_multiplexed_async_connection().await.unwrap();
    let _: redis::RedisResult<()> = redis::cmd("DEL")
        .arg(format!("idempotency:{key}"))
        .query_async(&mut conn)
        .await;
}

#[tokio::test]
#[ignore = "requires disposable local PostgreSQL and Redis"]
async fn idempotency_key_never_replays_a_response_to_an_unauthenticated_caller() {
    let database_url = require_local("VEEA_TEST_DATABASE_URL", ["@127.0.0.1:", "@localhost:"]);
    let redis_url = require_local("VEEA_TEST_REDIS_URL", ["//127.0.0.1:", "//localhost:"]);

    // One schema per run, so the test never touches data it did not create.
    let admin = PgPoolOptions::new()
        .max_connections(2)
        .connect(&database_url)
        .await
        .unwrap();
    let schema = format!("veea_test_{}", Uuid::new_v4().simple());
    sqlx::query(&format!("CREATE SCHEMA {schema}"))
        .execute(&admin)
        .await
        .unwrap();
    let selected = schema.clone();
    let pool: PgPool = PgPoolOptions::new()
        .max_connections(4)
        .after_connect(move |conn, _| {
            let selected = selected.clone();
            Box::pin(async move {
                sqlx::query(&format!("SET search_path TO {selected}"))
                    .execute(conn)
                    .await?;
                Ok(())
            })
        })
        .connect(&database_url)
        .await
        .unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();

    let redis =
        redis::aio::ConnectionManager::new(redis::Client::open(redis_url.as_str()).unwrap())
            .await
            .unwrap();
    let state = AppState::new(
        config(&database_url, &redis_url),
        pool.clone(),
        redis,
        MessagingConnection::Disabled,
    );
    let app = build_router(state);

    let outcome = scenario(&app).await;

    // Cleanup comes before the assertions so a failing run leaves nothing behind.
    forget_key(&redis_url, &outcome.key).await;
    pool.close().await;
    sqlx::query(&format!("DROP SCHEMA {schema} CASCADE"))
        .execute(&admin)
        .await
        .unwrap();
    admin.close().await;

    // Control: the authenticated request really did return the profile.
    assert_eq!(
        outcome.profile.status,
        StatusCode::OK,
        "{}",
        outcome.profile.body
    );
    assert!(outcome.profile.body.contains(&outcome.email));
    assert!(!outcome.profile.replayed);

    // N1: same key, no token => normal 401, never the cached profile.
    assert_eq!(
        outcome.anonymous_repeat.status,
        StatusCode::UNAUTHORIZED,
        "unauthenticated request was answered with: {}",
        outcome.anonymous_repeat.body
    );
    assert!(
        !outcome.anonymous_repeat.replayed,
        "replay header leaked to an anonymous caller"
    );
    assert!(!outcome.anonymous_repeat.body.contains(&outcome.email));

    // Same key on a failed login => the normal auth error, not the profile.
    assert_eq!(
        outcome.wrong_password_login.status,
        StatusCode::UNAUTHORIZED
    );
    assert!(!outcome.wrong_password_login.replayed);
    assert!(!outcome.wrong_password_login.body.contains(&outcome.email));
    assert!(outcome.wrong_password_login.body.contains("UNAUTHORIZED"));
}
