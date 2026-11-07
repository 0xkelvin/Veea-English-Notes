//! Run only against a disposable local PostgreSQL database:
//! VEEA_TEST_DATABASE_URL=postgres://... cargo test --test account_data_integration -- --ignored
use chrono::Utc;
use english_notes_cloud::{
    application::{
        identity::phone_auth,
        vocabulary::{
            commands::sync_words::{self, SyncWordsCommand},
            dto::word_dto::{SyncRequest, WordPayload},
        },
    },
    common::result::AppResult,
    infrastructure::{
        persistence::postgres::PgWordRepository, security::otp_delivery::OtpDelivery,
    },
};
use sqlx::{PgPool, postgres::PgPoolOptions};
use std::sync::atomic::{AtomicUsize, Ordering};
use uuid::Uuid;

struct Delivery {
    checks: AtomicUsize,
}
impl OtpDelivery for Delivery {
    fn available(&self) -> bool {
        true
    }
    async fn send(&self, _: &str) -> AppResult<String> {
        Ok(format!("VE{}", Uuid::new_v4()))
    }
    async fn check(&self, _: &str, _: &str, code: &str) -> AppResult<bool> {
        self.checks.fetch_add(1, Ordering::SeqCst);
        Ok(code == "123456")
    }
}
async fn fixture() -> (PgPool, PgPool, String) {
    let url =
        std::env::var("VEEA_TEST_DATABASE_URL").expect("Set a disposable local test database URL");
    assert!(
        url.contains("@127.0.0.1:") || url.contains("@localhost:"),
        "Use a disposable local database only"
    );
    let admin = PgPoolOptions::new()
        .max_connections(2)
        .connect(&url)
        .await
        .unwrap();
    let schema = format!("veea_test_{}", Uuid::new_v4().simple());
    sqlx::query(&format!("CREATE SCHEMA {schema}"))
        .execute(&admin)
        .await
        .unwrap();
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
        .connect(&url)
        .await
        .unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    (pool, admin, schema)
}
async fn clean(pool: PgPool, admin: PgPool, schema: String) {
    pool.close().await;
    sqlx::query(&format!("DROP SCHEMA {schema} CASCADE"))
        .execute(&admin)
        .await
        .unwrap();
    admin.close().await;
}
#[tokio::test]
#[ignore = "requires a disposable local PostgreSQL database"]
async fn otp_is_expiring_bounded_single_use_and_purpose_bound() {
    let (pool, admin, schema) = fixture().await;
    let delivery = Delivery {
        checks: AtomicUsize::new(0),
    };
    let challenge =
        phone_auth::request_challenge(&pool, &delivery, "0901234567", "signin", None, "127.0.0.1")
            .await
            .unwrap();
    assert!(
        phone_auth::request_challenge(&pool, &delivery, "0901234567", "signin", None, "127.0.0.1")
            .await
            .is_err()
    );
    assert!(
        phone_auth::consume_challenge(
            &pool,
            &delivery,
            challenge.challenge_id,
            "123456",
            "delete",
            None
        )
        .await
        .is_err()
    );
    assert_eq!(delivery.checks.load(Ordering::SeqCst), 0);
    assert!(
        phone_auth::consume_challenge(
            &pool,
            &delivery,
            challenge.challenge_id,
            "000000",
            "signin",
            None
        )
        .await
        .is_err()
    );
    let (a, b) = tokio::join!(
        phone_auth::consume_challenge(
            &pool,
            &delivery,
            challenge.challenge_id,
            "123456",
            "signin",
            None
        ),
        phone_auth::consume_challenge(
            &pool,
            &delivery,
            challenge.challenge_id,
            "123456",
            "signin",
            None
        )
    );
    assert_ne!(a.is_ok(), b.is_ok());
    assert!(
        phone_auth::consume_challenge(
            &pool,
            &delivery,
            challenge.challenge_id,
            "123456",
            "signin",
            None
        )
        .await
        .is_err()
    );
    let expired =
        phone_auth::request_challenge(&pool, &delivery, "0901234568", "signin", None, "127.0.0.1")
            .await
            .unwrap();
    sqlx::query("UPDATE otp_challenges SET expires_at = now() - INTERVAL '1 second' WHERE id = $1")
        .bind(expired.challenge_id)
        .execute(&pool)
        .await
        .unwrap();
    assert!(
        phone_auth::consume_challenge(
            &pool,
            &delivery,
            expired.challenge_id,
            "123456",
            "signin",
            None
        )
        .await
        .is_err()
    );
    let bounded =
        phone_auth::request_challenge(&pool, &delivery, "0901234569", "signin", None, "127.0.0.1")
            .await
            .unwrap();
    for _ in 0..5 {
        assert!(
            phone_auth::consume_challenge(
                &pool,
                &delivery,
                bounded.challenge_id,
                "000000",
                "signin",
                None
            )
            .await
            .is_err()
        );
    }
    assert!(
        phone_auth::consume_challenge(
            &pool,
            &delivery,
            bounded.challenge_id,
            "123456",
            "signin",
            None
        )
        .await
        .is_err()
    );
    clean(pool, admin, schema).await;
}
#[tokio::test]
#[ignore = "requires a disposable local PostgreSQL database"]
async fn revisions_page_tied_batches_and_reject_foreign_word_ids() {
    let (pool, admin, schema) = fixture().await;
    let user = Uuid::new_v4();
    let other = Uuid::new_v4();
    for (id, email) in [(user, "a@veea.test"), (other, "b@veea.test")] {
        sqlx::query("INSERT INTO users(id,email,password_hash) VALUES($1,$2,'unused')")
            .bind(id)
            .bind(email)
            .execute(&pool)
            .await
            .unwrap();
    }
    let repo = PgWordRepository::new(pool.clone());
    let now = Utc::now();
    let rows: Vec<_> = (0..500)
        .map(|n| WordPayload {
            id: Uuid::new_v4(),
            word: format!("word{n}"),
            meaning: "saved meaning".into(),
            pronunciation: None,
            part_of_speech: None,
            source: None,
            examples: vec![],
            tags: vec![],
            date: "2026-11-07".into(),
            created_at: now,
            updated_at: now,
            deleted: false,
        })
        .collect();
    let first = sync_words::handle(
        SyncWordsCommand {
            user_id: user,
            request: SyncRequest {
                changes: rows.clone(),
                since: None,
                cursor: Some("0".into()),
            },
        },
        &repo,
    )
    .await
    .unwrap();
    assert_eq!(first.accepted.len(), 500);
    let mut extra = rows[0].clone();
    extra.id = Uuid::new_v4();
    sync_words::handle(
        SyncWordsCommand {
            user_id: user,
            request: SyncRequest {
                changes: vec![extra],
                since: None,
                cursor: Some(first.cursor),
            },
        },
        &repo,
    )
    .await
    .unwrap();
    let page = sync_words::handle(
        SyncWordsCommand {
            user_id: user,
            request: SyncRequest {
                changes: vec![],
                since: None,
                cursor: Some("0".into()),
            },
        },
        &repo,
    )
    .await
    .unwrap();
    assert!(page.has_more);
    assert_eq!(page.changes.len(), 500);
    let last = sync_words::handle(
        SyncWordsCommand {
            user_id: user,
            request: SyncRequest {
                changes: vec![],
                since: None,
                cursor: Some(page.cursor),
            },
        },
        &repo,
    )
    .await
    .unwrap();
    assert_eq!(last.changes.len(), 1);
    assert!(!last.has_more);
    let foreign = sync_words::handle(
        SyncWordsCommand {
            user_id: other,
            request: SyncRequest {
                changes: vec![rows[0].clone()],
                since: None,
                cursor: Some("0".into()),
            },
        },
        &repo,
    )
    .await
    .unwrap();
    assert!(foreign.accepted.is_empty());
    assert!(foreign.canonical.is_empty());
    assert!(foreign.changes.is_empty());
    clean(pool, admin, schema).await;
}
