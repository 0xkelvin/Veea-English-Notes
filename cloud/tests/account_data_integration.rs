//! Run only against a disposable local PostgreSQL database:
//! VEEA_TEST_DATABASE_URL=postgres://... cargo test --test account_data_integration -- --ignored
use chrono::Utc;
use english_notes_cloud::{
    application::{
        identity::{
            phone_auth,
            ports::{clock::SystemClock, id_generator::UuidGenerator},
        },
        vocabulary::{
            commands::sync_words::{self, SyncWordsCommand},
            dto::word_dto::{SyncRequest, WordPayload},
        },
    },
    common::{error::AppError, result::AppResult},
    infrastructure::{
        persistence::postgres::{
            PgOutboxRepository, PgRefreshTokenRepository, PgUserRepository, PgWordRepository,
        },
        security::{Argon2PasswordHasher, JwtServiceImpl, otp_delivery::OtpDelivery},
    },
};
use secrecy::SecretString;
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

// ── Phone change and deletion ──────────────────────────────────────────────

const CODE: &str = "123456";

struct Deps {
    users: PgUserRepository,
    refresh: PgRefreshTokenRepository,
    outbox: PgOutboxRepository,
    hasher: Argon2PasswordHasher,
    jwt: JwtServiceImpl,
    delivery: Delivery,
}

fn deps(pool: &PgPool) -> Deps {
    Deps {
        users: PgUserRepository::new(pool.clone()),
        refresh: PgRefreshTokenRepository::new(pool.clone()),
        outbox: PgOutboxRepository::new(pool.clone()),
        hasher: Argon2PasswordHasher::new(),
        jwt: JwtServiceImpl::new(
            &SecretString::from("integration-test-secret-integration-test".to_string()),
            "veea-test".into(),
            "veea-test".into(),
        ),
        delivery: Delivery {
            checks: AtomicUsize::new(0),
        },
    }
}

/// Moves every challenge out of the send-rate windows so a test can send again.
async fn cool_down(pool: &PgPool) {
    sqlx::query("UPDATE otp_challenges SET created_at = created_at - INTERVAL '61 minutes'")
        .execute(pool)
        .await
        .unwrap();
}

fn uuid_of(value: &serde_json::Value) -> Uuid {
    value["user_id"].as_str().unwrap().parse().unwrap()
}

async fn sign_in(pool: &PgPool, d: &Deps, phone: &str) -> serde_json::Value {
    cool_down(pool).await;
    let c = phone_auth::request_challenge(pool, &d.delivery, phone, "signin", None, "10.0.0.1")
        .await
        .unwrap();
    let verified =
        phone_auth::consume_challenge(pool, &d.delivery, c.challenge_id, CODE, "signin", None)
            .await
            .unwrap();
    phone_auth::sign_in_verified(
        verified,
        pool,
        &d.users,
        &d.refresh,
        &d.outbox,
        &d.hasher,
        &d.jwt,
        &SystemClock,
        &UuidGenerator,
        900,
        86_400,
    )
    .await
    .unwrap()
}

async fn prove_current(pool: &PgPool, d: &Deps, user: Uuid) -> Uuid {
    cool_down(pool).await;
    let c = phone_auth::request_current_phone_code(pool, &d.delivery, user, "10.0.0.2")
        .await
        .unwrap();
    phone_auth::verify_current_phone(pool, &d.delivery, user, c.challenge_id, CODE)
        .await
        .unwrap()
        .proof_id
}

async fn new_code(
    pool: &PgPool,
    d: &Deps,
    user: Uuid,
    proof: Uuid,
    phone: &str,
) -> AppResult<Uuid> {
    cool_down(pool).await;
    phone_auth::request_new_phone_code(pool, &d.delivery, user, proof, phone, "10.0.0.3")
        .await
        .map(|c| c.challenge_id)
}

async fn confirm(
    pool: &PgPool,
    d: &Deps,
    user: Uuid,
    challenge: Uuid,
    code: &str,
) -> AppResult<serde_json::Value> {
    phone_auth::confirm_phone_change(
        pool,
        &d.delivery,
        user,
        challenge,
        code,
        &d.users,
        &d.refresh,
        &d.outbox,
        &d.jwt,
        &SystemClock,
        &UuidGenerator,
        900,
        86_400,
    )
    .await
}

async fn phone_of(pool: &PgPool, user: Uuid) -> Option<String> {
    sqlx::query_as::<_, (Option<String>,)>("SELECT phone FROM users WHERE id = $1")
        .bind(user)
        .fetch_optional(pool)
        .await
        .unwrap()
        .and_then(|r| r.0)
}

async fn active_sessions(pool: &PgPool, user: Uuid) -> i64 {
    sqlx::query_as::<_, (i64,)>(
        "SELECT COUNT(*) FROM refresh_tokens WHERE user_id = $1 AND revoked_at IS NULL",
    )
    .bind(user)
    .fetch_one(pool)
    .await
    .unwrap()
    .0
}

async fn seed_word(pool: &PgPool, user: Uuid) -> String {
    let repo = PgWordRepository::new(pool.clone());
    let now = Utc::now();
    let id = Uuid::new_v4();
    let result = sync_words::handle(
        SyncWordsCommand {
            user_id: user,
            request: SyncRequest {
                changes: vec![WordPayload {
                    id,
                    word: "resilient".into(),
                    meaning: "kien cuong".into(),
                    pronunciation: None,
                    part_of_speech: None,
                    source: None,
                    examples: vec![],
                    tags: vec![],
                    date: "2026-11-10".into(),
                    created_at: now,
                    updated_at: now,
                    deleted: false,
                }],
                since: None,
                cursor: Some("0".into()),
            },
        },
        &repo,
    )
    .await
    .unwrap();
    result.cursor
}

#[tokio::test]
#[ignore = "requires a disposable local PostgreSQL database"]
async fn phone_change_keeps_uuid_notebook_and_cursor_and_replaces_sessions() {
    let (pool, admin, schema) = fixture().await;
    let d = deps(&pool);
    let first = sign_in(&pool, &d, "0901000001").await;
    let user = uuid_of(&first);
    sign_in(&pool, &d, "0901000001").await; // a second device
    assert_eq!(active_sessions(&pool, user).await, 2);
    let cursor = seed_word(&pool, user).await;

    let proof = prove_current(&pool, &d, user).await;
    let challenge = new_code(&pool, &d, user, proof, "0901000002")
        .await
        .unwrap();
    // A wrong new-phone code changes nothing.
    assert!(matches!(
        confirm(&pool, &d, user, challenge, "000000").await,
        Err(AppError::Validation(_))
    ));
    assert_eq!(phone_of(&pool, user).await.as_deref(), Some("+84901000001"));
    assert_eq!(active_sessions(&pool, user).await, 2);

    let session = confirm(&pool, &d, user, challenge, CODE).await.unwrap();
    assert_eq!(uuid_of(&session), user, "account UUID must not change");
    assert_eq!(session["identifier"], "+84901000002");
    assert_eq!(session["revoked_sessions"], 2);
    assert_eq!(phone_of(&pool, user).await.as_deref(), Some("+84901000002"));
    assert_eq!(
        active_sessions(&pool, user).await,
        1,
        "old sessions revoked, one replacement minted"
    );
    let event: (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM outbox_events WHERE aggregate_id = $1 AND event_type ILIKE '%identifier%'",
    )
    .bind(user)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(event.0, 1);

    // Notebook and cursor stay with the same UUID: nothing new to pull.
    let page = sync_words::handle(
        SyncWordsCommand {
            user_id: user,
            request: SyncRequest {
                changes: vec![],
                since: None,
                cursor: Some(cursor),
            },
        },
        &PgWordRepository::new(pool.clone()),
    )
    .await
    .unwrap();
    assert!(page.changes.is_empty());
    let owned: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM words WHERE user_id = $1")
        .bind(user)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(owned.0, 1);

    // Replays: the proof and the new-phone code are each single-use.
    assert!(matches!(
        new_code(&pool, &d, user, proof, "0901000003").await,
        Err(AppError::NotFound(_))
    ));
    assert!(confirm(&pool, &d, user, challenge, CODE).await.is_err());
    assert_eq!(phone_of(&pool, user).await.as_deref(), Some("+84901000002"));

    // The new number signs in to the same account; the old number is free and
    // creates a different, empty account.
    assert_eq!(uuid_of(&sign_in(&pool, &d, "0901000002").await), user);
    let reused = uuid_of(&sign_in(&pool, &d, "0901000001").await);
    assert_ne!(reused, user);
    clean(pool, admin, schema).await;
}

#[tokio::test]
#[ignore = "requires a disposable local PostgreSQL database"]
async fn phone_change_proofs_are_bound_to_purpose_account_and_freshness() {
    let (pool, admin, schema) = fixture().await;
    let d = deps(&pool);
    let a = uuid_of(&sign_in(&pool, &d, "0902000001").await);
    let b = uuid_of(&sign_in(&pool, &d, "0902000002").await);

    // A sign-in challenge is not a current-phone proof.
    cool_down(&pool).await;
    let signin =
        phone_auth::request_challenge(&pool, &d.delivery, "0902000001", "signin", None, "10.0.1.1")
            .await
            .unwrap();
    assert!(
        phone_auth::verify_current_phone(&pool, &d.delivery, a, signin.challenge_id, CODE)
            .await
            .is_err()
    );
    // Another account cannot verify A's current-phone code.
    cool_down(&pool).await;
    let current = phone_auth::request_current_phone_code(&pool, &d.delivery, a, "10.0.1.2")
        .await
        .unwrap();
    assert!(
        phone_auth::verify_current_phone(&pool, &d.delivery, b, current.challenge_id, CODE)
            .await
            .is_err()
    );
    // An unverified current-phone challenge is not a proof.
    assert!(matches!(
        new_code(&pool, &d, a, current.challenge_id, "0902000009").await,
        Err(AppError::NotFound(_))
    ));
    // A deletion code is not a proof.
    cool_down(&pool).await;
    let delete = phone_auth::request_challenge(
        &pool,
        &d.delivery,
        "0902000001",
        "delete",
        Some(a),
        "10.0.1.3",
    )
    .await
    .unwrap();
    phone_auth::consume_challenge(
        &pool,
        &d.delivery,
        delete.challenge_id,
        CODE,
        "delete",
        Some(a),
    )
    .await
    .unwrap();
    assert!(matches!(
        new_code(&pool, &d, a, delete.challenge_id, "0902000009").await,
        Err(AppError::NotFound(_))
    ));

    let proof = prove_current(&pool, &d, a).await;
    // B cannot use A's proof.
    assert!(matches!(
        new_code(&pool, &d, b, proof, "0902000009").await,
        Err(AppError::NotFound(_))
    ));
    // Unchanged or invalid numbers are rejected without sending.
    assert!(matches!(
        new_code(&pool, &d, a, proof, "0902000001").await,
        Err(AppError::Validation(_))
    ));
    assert!(matches!(
        new_code(&pool, &d, a, proof, "12345").await,
        Err(AppError::Validation(_))
    ));
    let challenge = new_code(&pool, &d, a, proof, "0902000009").await.unwrap();
    // The new-phone code is bound to A and to its purpose.
    assert!(confirm(&pool, &d, b, challenge, CODE).await.is_err());
    assert!(
        phone_auth::consume_challenge(&pool, &d.delivery, challenge, CODE, "signin", None)
            .await
            .is_err()
    );
    // Resend with the same proof works; an expired proof no longer does.
    let resent = new_code(&pool, &d, a, proof, "0902000009").await.unwrap();
    sqlx::query(
        "UPDATE otp_challenges SET consumed_at = now() - INTERVAL '16 minutes' WHERE id = $1",
    )
    .bind(proof)
    .execute(&pool)
    .await
    .unwrap();
    assert!(matches!(
        new_code(&pool, &d, a, proof, "0902000009").await,
        Err(AppError::NotFound(_))
    ));
    assert!(matches!(
        confirm(&pool, &d, a, resent, CODE).await,
        Err(AppError::NotFound(_))
    ));
    assert_eq!(phone_of(&pool, a).await.as_deref(), Some("+84902000001"));
    assert_eq!(active_sessions(&pool, a).await, 1);
    clean(pool, admin, schema).await;
}

#[tokio::test]
#[ignore = "requires a disposable local PostgreSQL database"]
async fn phone_change_rejects_taken_numbers_and_stale_parallel_changes() {
    let (pool, admin, schema) = fixture().await;
    let d = deps(&pool);
    let a = uuid_of(&sign_in(&pool, &d, "0903000001").await);
    let b = uuid_of(&sign_in(&pool, &d, "0903000002").await);

    // Taking B's number: 409 after proof, nothing changes, the proof survives.
    let proof = prove_current(&pool, &d, a).await;
    let taken = new_code(&pool, &d, a, proof, "0903000002").await.unwrap();
    assert!(matches!(
        confirm(&pool, &d, a, taken, CODE).await,
        Err(AppError::Conflict(_))
    ));
    assert_eq!(phone_of(&pool, a).await.as_deref(), Some("+84903000001"));
    assert_eq!(phone_of(&pool, b).await.as_deref(), Some("+84903000002"));
    assert_eq!(active_sessions(&pool, a).await, 1);
    assert_eq!(active_sessions(&pool, b).await, 1);

    // Two sessions prove the same current number in parallel.
    let other_proof = prove_current(&pool, &d, a).await;
    let pending = new_code(&pool, &d, a, other_proof, "0903000004")
        .await
        .unwrap();
    let first = new_code(&pool, &d, a, proof, "0903000003").await.unwrap();
    confirm(&pool, &d, a, first, CODE).await.unwrap();
    assert_eq!(phone_of(&pool, a).await.as_deref(), Some("+84903000003"));
    // The second session's proof is for a number the account no longer has.
    assert!(matches!(
        confirm(&pool, &d, a, pending, CODE).await,
        Err(AppError::NotFound(_))
    ));
    assert!(matches!(
        new_code(&pool, &d, a, other_proof, "0903000005").await,
        Err(AppError::NotFound(_))
    ));
    assert_eq!(phone_of(&pool, a).await.as_deref(), Some("+84903000003"));

    // Two accounts swapping numbers at once: both conflict, no deadlock.
    let pa = prove_current(&pool, &d, a).await;
    let pb = prove_current(&pool, &d, b).await;
    let ca = new_code(&pool, &d, a, pa, "0903000002").await.unwrap();
    let cb = new_code(&pool, &d, b, pb, "0903000003").await.unwrap();
    let (ra, rb) = tokio::time::timeout(std::time::Duration::from_secs(20), async {
        tokio::join!(
            confirm(&pool, &d, a, ca, CODE),
            confirm(&pool, &d, b, cb, CODE)
        )
    })
    .await
    .expect("swap must not deadlock");
    assert!(matches!(ra, Err(AppError::Conflict(_))));
    assert!(matches!(rb, Err(AppError::Conflict(_))));
    assert_eq!(phone_of(&pool, a).await.as_deref(), Some("+84903000003"));
    assert_eq!(phone_of(&pool, b).await.as_deref(), Some("+84903000002"));
    clean(pool, admin, schema).await;
}

#[tokio::test]
#[ignore = "requires a disposable local PostgreSQL database"]
async fn deletion_needs_a_fresh_code_and_leaves_a_receipt_for_lost_responses() {
    let (pool, admin, schema) = fixture().await;
    let d = deps(&pool);
    let user = uuid_of(&sign_in(&pool, &d, "0904000001").await);
    seed_word(&pool, user).await;
    cool_down(&pool).await;
    let c = phone_auth::request_challenge(
        &pool,
        &d.delivery,
        "0904000001",
        "delete",
        Some(user),
        "10.0.2.1",
    )
    .await
    .unwrap();
    let delete = |code: &'static str| {
        phone_auth::delete_verified_account(
            &pool,
            &d.delivery,
            user,
            c.challenge_id,
            code,
            &d.users,
            &d.outbox,
            &SystemClock,
            &UuidGenerator,
        )
    };
    assert!(delete("000000").await.is_err());
    assert!(phone_of(&pool, user).await.is_some());
    assert!(
        !phone_auth::deletion_confirmed(&pool, user, c.challenge_id)
            .await
            .unwrap()
    );

    delete(CODE).await.unwrap();
    assert!(phone_of(&pool, user).await.is_none());
    for table in ["words", "refresh_tokens", "otp_challenges"] {
        let left: (i64,) =
            sqlx::query_as(&format!("SELECT COUNT(*) FROM {table} WHERE user_id = $1"))
                .bind(user)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(left.0, 0, "{table} rows must be removed");
    }
    // Retry after a lost response: the code is spent, but the receipt proves
    // the deletion. Other challenge ids or accounts prove nothing.
    assert!(delete(CODE).await.is_err());
    assert!(
        phone_auth::deletion_confirmed(&pool, user, c.challenge_id)
            .await
            .unwrap()
    );
    assert!(
        !phone_auth::deletion_confirmed(&pool, user, Uuid::new_v4())
            .await
            .unwrap()
    );
    assert!(
        !phone_auth::deletion_confirmed(&pool, Uuid::new_v4(), c.challenge_id)
            .await
            .unwrap()
    );
    clean(pool, admin, schema).await;
}
