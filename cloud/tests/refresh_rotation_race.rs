//! Regression tests for N2: rotating a refresh token must consume it exactly
//! once, atomically with persisting its replacement.
//!
//! Drives the real `build_router` with synthetic data. Run only against a
//! disposable local PostgreSQL and Redis:
//!
//! ```text
//! VEEA_TEST_DATABASE_URL=postgres://...@127.0.0.1:.../... \
//! VEEA_TEST_REDIS_URL=redis://127.0.0.1:... \
//!   cargo test --test refresh_rotation_race -- --ignored
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
use sqlx::{
    PgPool,
    postgres::{PgConnectOptions, PgPoolOptions},
};
use std::{
    str::FromStr,
    sync::Arc,
    time::{Duration, Instant},
};
use tower::ServiceExt;
use uuid::Uuid;

fn config(database_url: &str, redis_url: &str) -> Arc<AppConfig> {
    Arc::new(AppConfig {
        app: ServerConfig {
            name: "n2-regression".into(),
            env: AppEnvironment::Development,
            host: "127.0.0.1".into(),
            port: 0,
            workers: 1,
            request_timeout_secs: 30,
            body_limit_bytes: 1_048_576,
        },
        database: DatabaseConfig {
            url: SecretString::from(database_url.to_string()),
            max_connections: 8,
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
            secret: SecretString::from("n2-regression-secret-for-local-tests-only-0123456789"),
            issuer: "n2-regression".into(),
            audience: "n2-regression".into(),
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
            service_name: "n2-regression".into(),
            enabled: false,
        },
        outbox: OutboxConfig {
            poll_interval_ms: 500,
            batch_size: 1,
            max_retries: 1,
        },
        // `oneshot` has no peer IP, so every request shares one rate-limit bucket.
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

/// A real router over its own schema. The app's connections carry the schema
/// name as `application_name`, so the test can see exactly which of *its*
/// backends are waiting on a lock.
struct Harness {
    app: Router,
    pool: PgPool,
    admin: PgPool,
    schema: String,
}

impl Harness {
    async fn start() -> Self {
        let database_url = require_local("VEEA_TEST_DATABASE_URL", ["@127.0.0.1:", "@localhost:"]);
        let redis_url = require_local("VEEA_TEST_REDIS_URL", ["//127.0.0.1:", "//localhost:"]);

        let admin = PgPoolOptions::new()
            .max_connections(3)
            .connect(&database_url)
            .await
            .unwrap();
        let schema = format!("veea_test_{}", Uuid::new_v4().simple());
        sqlx::query(&format!("CREATE SCHEMA {schema}"))
            .execute(&admin)
            .await
            .unwrap();

        let options = PgConnectOptions::from_str(&database_url)
            .unwrap()
            .application_name(&schema);
        let selected = schema.clone();
        let pool = PgPoolOptions::new()
            .max_connections(8)
            .after_connect(move |conn, _| {
                let selected = selected.clone();
                Box::pin(async move {
                    sqlx::query(&format!("SET search_path TO {selected}"))
                        .execute(conn)
                        .await?;
                    Ok(())
                })
            })
            .connect_with(options)
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
        Self {
            app: build_router(state),
            pool,
            admin,
            schema,
        }
    }

    async fn stop(self) {
        self.pool.close().await;
        sqlx::query(&format!("DROP SCHEMA {} CASCADE", self.schema))
            .execute(&self.admin)
            .await
            .unwrap();
        self.admin.close().await;
    }

    /// Registers a synthetic email account and returns its first refresh token.
    async fn register(&self) -> String {
        let email = format!("n2-{}@example.com", Uuid::new_v4().simple());
        let (status, body) = post(
            &self.app,
            "/api/v1/auth/register",
            serde_json::json!({ "identifier": email, "password": "synthetic-Passw0rd-2" }),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED, "setup failed: {body}");
        body["data"]["tokens"]["refresh_token"]
            .as_str()
            .unwrap()
            .to_string()
    }

    async fn active_sessions(&self) -> i64 {
        sqlx::query_scalar(&format!(
            "SELECT COUNT(*) FROM {}.refresh_tokens WHERE revoked_at IS NULL",
            self.schema
        ))
        .fetch_one(&self.admin)
        .await
        .unwrap()
    }

    /// How many of this harness's backends are blocked inside an
    /// `UPDATE refresh_tokens ...` waiting for a lock.
    async fn refreshes_waiting_on_lock(&self) -> i64 {
        sqlx::query_scalar(
            "SELECT COUNT(*) FROM pg_stat_activity
             WHERE application_name = $1
               AND wait_event_type = 'Lock'
               AND query ILIKE 'UPDATE refresh_tokens%'",
        )
        .bind(&self.schema)
        .fetch_one(&self.admin)
        .await
        .unwrap()
    }
}

async fn post(
    app: &Router,
    path: &str,
    json: serde_json::Value,
) -> (StatusCode, serde_json::Value) {
    let request = Request::builder()
        .method("POST")
        .uri(path)
        .header("content-type", "application/json")
        .body(Body::from(json.to_string()))
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .unwrap();
    let body = serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null);
    (status, body)
}

async fn refresh(app: &Router, token: &str) -> (StatusCode, serde_json::Value) {
    post(
        app,
        "/api/v1/auth/refresh",
        serde_json::json!({ "refresh_token": token }),
    )
    .await
}

#[tokio::test]
#[ignore = "requires disposable local PostgreSQL and Redis"]
async fn concurrent_refreshes_with_one_token_issue_exactly_one_replacement() {
    let h = Harness::start().await;
    let original = h.register().await;

    // Barrier: hold the token row so both requests pass every read-side check
    // and then queue on the write that consumes the token. Plain SELECTs are
    // not blocked by FOR UPDATE, so neither request can observe the other.
    let mut blocker = h.admin.begin().await.unwrap();
    sqlx::query(&format!(
        "SELECT id FROM {}.refresh_tokens FOR UPDATE",
        h.schema
    ))
    .execute(&mut *blocker)
    .await
    .unwrap();

    let first = tokio::spawn({
        let app = h.app.clone();
        let token = original.clone();
        async move { refresh(&app, &token).await }
    });
    let second = tokio::spawn({
        let app = h.app.clone();
        let token = original.clone();
        async move { refresh(&app, &token).await }
    });

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut both_waiting = false;
    while Instant::now() < deadline {
        if h.refreshes_waiting_on_lock().await == 2 {
            both_waiting = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    blocker.rollback().await.unwrap();

    let results = [first.await.unwrap(), second.await.unwrap()];
    let issued: Vec<String> = results
        .iter()
        .filter(|(status, _)| *status == StatusCode::OK)
        .map(|(_, body)| body["data"]["refresh_token"].as_str().unwrap().to_string())
        .collect();
    let active_after_race = h.active_sessions().await;
    let original_reused = refresh(&h.app, &original).await.0;
    let winner_works = match issued.as_slice() {
        [only] => Some(refresh(&h.app, only).await.0),
        _ => None,
    };
    h.stop().await;

    assert!(
        both_waiting,
        "barrier not reached: both refreshes never queued on the consuming UPDATE together"
    );
    let statuses: Vec<StatusCode> = results.iter().map(|(status, _)| *status).collect();
    assert_eq!(
        issued.len(),
        1,
        "one refresh token produced {} replacement sessions (statuses {statuses:?})",
        issued.len()
    );
    assert!(statuses.contains(&StatusCode::UNAUTHORIZED), "{statuses:?}");
    assert_eq!(active_after_race, 1, "exactly one live session must remain");
    assert_eq!(original_reused, StatusCode::UNAUTHORIZED);
    assert_eq!(winner_works, Some(StatusCode::OK));
}

#[tokio::test]
#[ignore = "requires disposable local PostgreSQL and Redis"]
async fn failed_replacement_write_rolls_back_consumption_of_the_old_token() {
    let h = Harness::start().await;
    let original = h.register().await;

    // Make every new refresh_tokens row fail, in this test's schema only.
    let schema = &h.schema;
    sqlx::query(&format!(
        "CREATE FUNCTION {schema}.n2_fail_insert() RETURNS trigger LANGUAGE plpgsql AS
         $$ BEGIN RAISE EXCEPTION 'synthetic replacement write failure'; END $$"
    ))
    .execute(&h.admin)
    .await
    .unwrap();
    sqlx::query(&format!(
        "CREATE TRIGGER n2_fail_insert BEFORE INSERT ON {schema}.refresh_tokens
         FOR EACH ROW EXECUTE FUNCTION {schema}.n2_fail_insert()"
    ))
    .execute(&h.admin)
    .await
    .unwrap();

    let (failed_status, _) = refresh(&h.app, &original).await;
    let still_active = h.active_sessions().await;

    sqlx::query(&format!(
        "DROP TRIGGER n2_fail_insert ON {schema}.refresh_tokens"
    ))
    .execute(&h.admin)
    .await
    .unwrap();
    let (retry_status, _) = refresh(&h.app, &original).await;
    h.stop().await;

    assert_eq!(failed_status, StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(
        still_active, 1,
        "a failed replacement write must leave the old token usable"
    );
    assert_eq!(
        retry_status,
        StatusCode::OK,
        "the old token must still rotate once the write succeeds"
    );
}
