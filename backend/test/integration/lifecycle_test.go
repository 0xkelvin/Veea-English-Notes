//go:build integration

package integration

import (
	"context"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/otp"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/lifecycle"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/maintenance"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/migrate"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
	"github.com/google/uuid"
	"strings"
	"testing"
)

const pathDeactivate = "/v1/me/deactivate"

type rightsProof struct{ action, id, cap, token, code string }

func (p rightsProof) completePath() string {
	return "/v1/account-rights/" + p.action + "/" + p.id + "/complete"
}
func (p rightsProof) statusPath() string {
	kind := "exports"
	if p.action == "delete" {
		kind = "deletions"
	}
	return "/v1/account-rights/" + kind + "/" + p.id
}
func rightsHeaders(cap string) []string { return []string{"Authorization", "Rights " + cap} }
func (p rightsProof) body() map[string]string {
	b := map[string]string{"challenge_token": p.token, "code": p.code}
	if p.action == "delete" {
		b["confirm"] = "delete_account"
	}
	return b
}
func (e *signupEnv) rightsStart(t *testing.T, action, email string) (rightsProof, response) {
	t.Helper()
	code := e.queueCode()
	r := e.post(t, "/v1/account-rights/"+action+"/start", map[string]string{"email": email})
	p := rightsProof{action: action, id: r.str("operation_id"), cap: r.str("operation_token"), token: r.str("challenge_token"), code: code}
	e.remember(p.cap)
	return p, r
}
func (e *signupEnv) rightsComplete(t *testing.T, p rightsProof) response {
	t.Helper()
	return e.post(t, p.completePath(), p.body(), rightsHeaders(p.cap)...)
}
func (e *signupEnv) rightsStatus(t *testing.T, p rightsProof) response {
	t.Helper()
	return e.get(t, p.statusPath(), rightsHeaders(p.cap)...)
}
func (e *signupEnv) download(t *testing.T, p rightsProof) response {
	t.Helper()
	return e.get(t, p.statusPath()+"/download", rightsHeaders(p.cap)...)
}
func (e *signupEnv) deactivate(t *testing.T, access string, rev int) response {
	t.Helper()
	return e.post(t, pathDeactivate, map[string]any{"confirm": true, "expected_revision": rev}, bearer(access)...)
}
func (e *signupEnv) rightsRunner(t *testing.T) *maintenance.Runner {
	t.Helper()
	keys, err := notify.NewKeyring(notify.Key{ID: 1, Key: outboxKey1})
	if err != nil {
		t.Fatal(err)
	}
	jobs := lifecycle.New(e.d.Pool, nil, keys, e.hmac, e.metrics, nil)
	r, err := maintenance.New(maintenance.Config{Pool: e.d.Pool, AccountJob: jobs.RunBatch})
	if err != nil {
		t.Fatal(err)
	}
	return r
}
func (e *signupEnv) finishRightsJobs(t *testing.T) {
	t.Helper()
	r := e.rightsRunner(t)
	for range 12 {
		results := r.RunOnce(context.Background())
		noErrors(t, results)
		if rowCount(t, e.d.Pool, `SELECT count(*) FROM account_operations WHERE state='pending'`) == 0 {
			return
		}
	}
	t.Fatal("rights jobs did not finish")
}

func TestLifecycle_DeactivateReactivate(t *testing.T) {
	e := newSignupEnv(t, nil)
	u, pw := e.passwordUser(t)
	a, b := e.issue(t, u, "A"), e.issue(t, u, "B")
	foreign := e.issue(t, newUser(t, e.q), "Foreign")
	oldCode := e.queueCode()
	old := e.otpLoginStart(t, u.Email)
	wantStatus(t, old, 202)
	wantProblem(t, e.deactivate(t, a.AccessToken, 1), 409, "lifecycle_conflict")
	want204(t, e.deactivate(t, a.AccessToken, 0))
	e.assertRevokedPair(t, a)
	e.assertRevokedPair(t, b)
	wantStatus(t, e.me(t, foreign.AccessToken), 200)
	wantUnauthorized(t, e.deactivate(t, a.AccessToken, 0))
	wantProblem(t, e.login(t, u.Email, pw), 403, "account_unavailable")
	p, r := e.rightsStart(t, "reactivate", u.Email)
	wantStatus(t, r, 202)
	want204(t, e.rightsComplete(t, p))
	want204(t, e.rightsComplete(t, p))
	e.assertRevokedPair(t, a)
	wantProblem(t, e.otpLoginVerify(t, old.str("challenge_token"), oldCode), 400, "invalid_code")
	login := e.login(t, u.Email, pw)
	wantStatus(t, login, 200)
	if userID(login) != u.ID.String() {
		t.Fatal("reactivation replaced ID")
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM users WHERE id=$1 AND lifecycle_revision=2`, u.ID) != 1 {
		t.Fatal("lifecycle revision")
	}
}

func TestLifecycle_InactiveRestrictedExportAndDelete(t *testing.T) {
	for _, status := range []string{"active", "deactivated", "suspended"} {
		t.Run(status, func(t *testing.T) {
			e := newSignupEnv(t, nil)
			u := newUser(t, e.q)
			a := e.issue(t, u, "A")
			if status != "active" {
				mustExec(t, e.d.Pool, `UPDATE users SET status=$2::text, resume_status=CASE WHEN $2::text='suspended' THEN 'active' END, suspension_reason=CASE WHEN $2::text='suspended' THEN 'other' END WHERE id=$1`, u.ID, status)
			}
			p, r := e.rightsStart(t, "export", u.Email)
			wantStatus(t, r, 202)
			wantProblem(t, e.download(t, p), 409, "export_not_ready")
			wantStatus(t, e.rightsComplete(t, p), 202)
			wantUnauthorized(t, e.me(t, p.cap))
			wantUnauthorized(t, e.refresh(t, p.cap))
			e.finishRightsJobs(t)
			file := e.download(t, p)
			wantStatus(t, file, 200)
			account := file.body["account"].(map[string]any)
			if account["user_id"] != u.ID.String() || account["email"] != u.Email || len(account) != 8 {
				t.Fatal("export product projection/ownership")
			}
			for _, secret := range []string{"password_hash", "refresh_token", "audit_events", "code_hash"} {
				if strings.Contains(string(file.raw), secret) {
					t.Fatal("export includes auth data")
				}
			}
			// Suspended owner may delete/export but may never self-reactivate.
			if status == "suspended" {
				react, r := e.rightsStart(t, "reactivate", u.Email)
				wantStatus(t, r, 202)
				wantProblem(t, e.rightsComplete(t, react), 400, "invalid_code")
			}
			d, r := e.rightsStart(t, "delete", u.Email)
			wantStatus(t, r, 202)
			wantStatus(t, e.rightsComplete(t, d), 202)
			wantProblem(t, e.download(t, p), 409, "operation_canceled")
			if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action='account.export.cancel' AND target_user_id=$1 AND metadata->>'operation_id'=$2`, u.ID, p.id) != 1 {
				t.Fatal("export cancellation not audited with the deletion")
			}
			e.assertRevokedPair(t, a)
			if rowCount(t, e.d.Pool, `SELECT count(*) FROM users WHERE id=$1 AND status='pending_deletion'`, u.ID) != 1 {
				t.Fatal("deletion did not seal")
			}
			if rowCount(t, e.d.Pool, `SELECT count(*) FROM sessions WHERE user_id=$1 AND revoked_at IS NULL`, u.ID) != 0 {
				t.Fatal("inactive sessions not revoked atomically")
			}
		})
	}
}

func TestLifecycle_ProofBindingExpiryAndOwnership(t *testing.T) {
	for _, mode := range []string{"foreign cap", "foreign action", "foreign proof", "login proof", "expired", "attempts", "stale lifecycle", "stale email", "unknown"} {
		t.Run(mode, func(t *testing.T) {
			e := newSignupEnv(t, nil)
			u := newUser(t, e.q)
			p, r := e.rightsStart(t, "delete", u.Email)
			wantStatus(t, r, 202)
			original := p
			want := 400
			code := "invalid_code"
			switch mode {
			case "foreign cap":
				other, r := e.rightsStart(t, "delete", newUser(t, e.q).Email)
				wantStatus(t, r, 202)
				p.cap = other.cap
				want = 404
				code = "not_found"
			case "foreign action":
				p.action = "export"
				want = 404
				code = "not_found"
			case "foreign proof":
				other, r := e.rightsStart(t, "delete", newUser(t, e.q).Email)
				wantStatus(t, r, 202)
				p.token = other.token
				p.code = other.code
			case "login proof":
				c := e.queueCode()
				ack := e.otpLoginStart(t, u.Email)
				wantStatus(t, ack, 202)
				p.token = ack.str("challenge_token")
				p.code = c
			case "expired":
				mustExec(t, e.d.Pool, `UPDATE otp_challenges SET expires_at=now() WHERE token_hash=$1`, otp.HashToken(p.token))
			case "attempts":
				bad := p
				bad.code = wrongCode(p.code)
				for range 5 {
					wantProblem(t, e.rightsComplete(t, bad), 400, "invalid_code")
				}
				wantProblem(t, e.rightsComplete(t, p), 400, "code_attempts_exceeded")
				return
			case "stale lifecycle":
				mustExec(t, e.d.Pool, `UPDATE users SET lifecycle_revision=lifecycle_revision+1 WHERE id=$1`, u.ID)
				want = 409
				code = "lifecycle_conflict"
			case "stale email":
				mustExec(t, e.d.Pool, `UPDATE users SET email_revision=email_revision+1 WHERE id=$1`, u.ID)
				want = 409
				code = "lifecycle_conflict"
			case "unknown":
				p.id = uuid.NewString()
				want = 404
				code = "not_found"
			}
			wantProblem(t, e.rightsComplete(t, p), want, code)
			if rowCount(t, e.d.Pool, `SELECT count(*) FROM users WHERE id=$1 AND status='active'`, u.ID) != 1 {
				t.Fatal("rejected proof mutated owner")
			}
			if rowCount(t, e.d.Pool, `SELECT count(*) FROM account_operations WHERE id=$1 AND accepted_at IS NOT NULL`, uuid.MustParse(original.id)) != 0 {
				t.Fatal("rejected operation accepted")
			}
		})
	}
}

func TestLifecycle_DeletionReceiptPurgeAndNewSignup(t *testing.T) {
	e := newSignupEnv(t, nil)
	u, pw := e.passwordUser(t)
	a, b := e.issue(t, u, "A"), e.issue(t, u, "B")
	foreign := newUser(t, e.q)
	x := e.issue(t, foreign, "X")
	wantStatus(t, e.send(t, "PUT", pathProfile, profileInput(0), bearer(a.AccessToken)...), 200)
	oldCode := e.queueCode()
	old := e.otpLoginStart(t, u.Email)
	wantStatus(t, old, 202)
	resetCode := e.queueCode()
	reset := e.resetStart(t, u.Email)
	wantStatus(t, reset, 202)
	p, r := e.rightsStart(t, "delete", u.Email)
	wantStatus(t, r, 202)
	before := e.rightsStatus(t, p)
	wantStatus(t, before, 200)
	if before.str("state") != "awaiting_proof" {
		t.Fatal("premature receipt")
	}
	wantStatus(t, e.rightsComplete(t, p), 202)
	wantStatus(t, e.rightsComplete(t, p), 202)
	e.assertRevokedPair(t, a)
	e.assertRevokedPair(t, b)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM deletion_ledger WHERE user_id=$1`, u.ID) != 1 {
		t.Fatal("missing/duplicate ledger")
	}
	pending := e.rightsStatus(t, p)
	wantStatus(t, pending, 200)
	if pending.str("state") != "pending" || pending.body["backup_expiry_due_at"] != nil {
		t.Fatal("false completion")
	}
	signup := e.startOTP(t, u.Email)
	wantStatus(t, signup, 202)
	inertCode := "000000" // unused synthetic secret; cannot redeem the inert challenge
	wantProblem(t, e.verify(t, signup.str("challenge_token"), inertCode), 400, "invalid_code")
	e.finishRightsJobs(t)
	done := e.rightsStatus(t, p)
	wantStatus(t, done, 200)
	if done.str("state") != "completed" || done.body["backup_expiry_due_at"] == nil {
		t.Fatal("receipt not completed")
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM users WHERE id=$1`, u.ID) != 0 || rowCount(t, e.d.Pool, `SELECT count(*) FROM sessions WHERE user_id=$1`, u.ID) != 0 || rowCount(t, e.d.Pool, `SELECT count(*) FROM email_outbox WHERE user_id=$1`, u.ID) != 0 {
		t.Fatal("owned rows survived")
	}
	wantStatus(t, e.me(t, x.AccessToken), 200)
	wantProblem(t, e.login(t, u.Email, pw), 401, "invalid_credentials")
	wantProblem(t, e.otpLoginVerify(t, old.str("challenge_token"), oldCode), 400, "invalid_code")
	wantProblem(t, e.resetComplete(t, reset.str("challenge_token"), resetCode, newPassword()), 400, "invalid_code")
	mustExec(t, e.d.Pool, `UPDATE otp_cooldowns SET last_issued_at=now()-interval '2 minutes' WHERE purpose='signup'`)
	freshCode := e.queueCode()
	ack := e.startOTP(t, u.Email)
	wantStatus(t, ack, 202)
	created := e.verify(t, ack.str("challenge_token"), freshCode)
	wantStatus(t, created, 201)
	if userID(created) == u.ID.String() {
		t.Fatal("deleted identity restored")
	}
	if created.body["user"].(map[string]any)["profile"].(map[string]any)["display_name"] != nil {
		t.Fatal("old profile inherited")
	}
	wantStatus(t, e.rightsComplete(t, p), 202)
	if e.rightsStatus(t, p).str("state") != "completed" {
		t.Fatal("receipt changed after email reuse")
	}
	// A capability never transfers by mailbox/address ownership.
	bad := p
	bad.cap = created.str("access_token")
	wantProblem(t, e.rightsStatus(t, bad), 404, "not_found")
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE (actor_user_id=$1 OR target_user_id=$1) AND (ip IS NOT NULL OR email_hmac IS NOT NULL OR user_agent IS NOT NULL OR request_id IS NOT NULL)`, u.ID) != 0 {
		t.Fatal("audit not minimized")
	}
}

func TestLifecycle_PurgeRetriesPartialFailure(t *testing.T) {
	for _, stage := range []string{"minimize", "final"} {
		t.Run(stage, func(t *testing.T) {
			e := newSignupEnv(t, nil)
			u := newUser(t, e.q)
			a := e.issue(t, u, "A")
			p, r := e.rightsStart(t, "delete", u.Email)
			wantStatus(t, r, 202)
			wantStatus(t, e.rightsComplete(t, p), 202)
			mustExec(t, e.d.Pool, `CREATE FUNCTION fail_lifecycle() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic checkpoint failure'; END $$`)
			if stage == "minimize" {
				mustExec(t, e.d.Pool, `CREATE TRIGGER fail_lifecycle BEFORE UPDATE ON audit_events FOR EACH ROW EXECUTE FUNCTION fail_lifecycle()`)
			} else {
				mustExec(t, e.d.Pool, `CREATE TRIGGER fail_lifecycle BEFORE INSERT ON audit_events FOR EACH ROW WHEN (NEW.action='account.delete.complete') EXECUTE FUNCTION fail_lifecycle()`)
			}
			runner := e.rightsRunner(t)
			failed := false
			for range 12 {
				res := runner.RunOnce(context.Background())
				if resultOf(t, res, "account_lifecycle").Err != nil {
					failed = true
					break
				}
			}
			if !failed {
				t.Fatal("failure not exercised")
			}
			if e.rightsStatus(t, p).str("state") != "pending" || rowCount(t, e.d.Pool, `SELECT count(*) FROM users WHERE id=$1 AND status='pending_deletion'`, u.ID) != 1 {
				t.Fatal("failed purge released identity")
			}
			e.assertRevokedPair(t, a)
			if stage == "final" {
				if rowCount(t, e.d.Pool, `SELECT count(*) FROM otp_challenges WHERE user_id=$1`, u.ID) != 0 {
					t.Fatal("earlier cleanup not checkpointed")
				}
			}
			table := "audit_events"
			mustExec(t, e.d.Pool, `DROP TRIGGER fail_lifecycle ON `+table)
			e.finishRightsJobs(t)
			if e.rightsStatus(t, p).str("state") != "completed" {
				t.Fatal("retry not completed")
			}
			if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action='account.delete.complete' AND target_user_id=$1`, u.ID) != 1 {
				t.Fatal("duplicate completion event")
			}
		})
	}
}

func TestLifecycle_AcceptanceRollsBackWithAudit(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	a := e.issue(t, u, "A")
	p, r := e.rightsStart(t, "delete", u.Email)
	wantStatus(t, r, 202)
	mustExec(t, e.d.Pool, `CREATE FUNCTION fail_accept() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic acceptance failure'; END $$`)
	mustExec(t, e.d.Pool, `CREATE TRIGGER fail_accept BEFORE INSERT ON audit_events FOR EACH ROW WHEN (NEW.action='account.delete.request') EXECUTE FUNCTION fail_accept()`)
	wantProblem(t, e.rightsComplete(t, p), 500, "internal_error")
	wantStatus(t, e.me(t, a.AccessToken), 200)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM deletion_ledger`) != 0 || rowCount(t, e.d.Pool, `SELECT count(*) FROM otp_challenges WHERE token_hash=$1 AND consumed_at IS NOT NULL`, otp.HashToken(p.token)) != 0 {
		t.Fatal("partial acceptance")
	}
	mustExec(t, e.d.Pool, `DROP TRIGGER fail_accept ON audit_events`)
	wantStatus(t, e.rightsComplete(t, p), 202)
}

func TestLifecycle_ConcurrentDuplicateDeletion(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	p, r := e.rightsStart(t, "delete", u.Email)
	wantStatus(t, r, 202)
	release := managementGate(t, e, "account.delete.request")
	a, b := make(chan response, 1), make(chan response, 1)
	go func() { a <- e.rightsComplete(t, p) }()
	waitForLockWaiters(t, e, 1)
	go func() { b <- e.rightsComplete(t, p) }()
	waitForLockWaiters(t, e, 2)
	release()
	wantStatus(t, <-a, 202)
	wantStatus(t, <-b, 202)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM deletion_ledger`) != 1 || rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action='account.delete.request'`) != 1 {
		t.Fatal("duplicate deletion")
	}
	wantMetric(t, e.metrics, `account_lifecycle_accepted_total{action="delete"}`, 1)
	wantStatus(t, e.rightsComplete(t, p), 202) // a later retry replays the receipt and counts nothing
	wantMetric(t, e.metrics, `account_lifecycle_accepted_total{action="delete"}`, 1)
	mustExec(t, e.d.Pool, `UPDATE account_operations SET accepted_at=accepted_at-interval '25 hours' WHERE id=$1`, uuid.MustParse(p.id))
	if age := metricValue(t, scrapeMetrics(t, e.metrics), `account_deletion_oldest_pending_seconds`); age < 25*3600 {
		t.Fatalf("purge backlog age %v does not show the overdue deletion", age)
	}
	e.finishRightsJobs(t)
	wantMetric(t, e.metrics, `account_deletion_oldest_pending_seconds`, 0)
	wantMetric(t, e.metrics, `account_jobs_total{job="delete",result="completed"}`, 1)
}

func TestLifecycle_TransitionVsIssuance(t *testing.T) {
	for _, transition := range []string{"delete", "deactivate"} {
		for _, first := range []string{"issuance", "transition"} {
			for _, flow := range []string{"password", "otp"} {
				t.Run(transition+"/"+first+"/"+flow, func(t *testing.T) {
					e := newSignupEnv(t, nil)
					u, pw := e.passwordUser(t)
					a := e.issue(t, u, "A")
					var p rightsProof
					if transition == "delete" {
						var r response
						p, r = e.rightsStart(t, "delete", u.Email)
						wantStatus(t, r, 202)
					}
					loginCode, loginToken := "", ""
					if flow == "otp" {
						loginCode = e.queueCode()
						ack := e.otpLoginStart(t, u.Email)
						wantStatus(t, ack, 202)
						loginToken = ack.str("challenge_token")
					}
					action := "account.delete.request"
					if transition == "deactivate" {
						action = "account.deactivate"
					}
					if first == "issuance" {
						action = "auth.password.login"
						if flow == "otp" {
							action = "auth.otp.verify"
						}
					}
					release := managementGate(t, e, action)
					issued, changed := make(chan response, 1), make(chan response, 1)
					issue := func() {
						if flow == "otp" {
							issued <- e.otpLoginVerify(t, loginToken, loginCode)
						} else {
							issued <- e.login(t, u.Email, pw)
						}
					}
					change := func() {
						if transition == "delete" {
							changed <- e.rightsComplete(t, p)
						} else {
							changed <- e.deactivate(t, a.AccessToken, 0)
						}
					}
					if first == "issuance" {
						go issue()
					} else {
						go change()
					}
					waitForLockWaiters(t, e, 1)
					if first == "issuance" {
						go change()
					} else {
						go issue()
					}
					waitForLockWaiters(t, e, 2)
					release()
					r := <-changed
					if transition == "delete" {
						wantStatus(t, r, 202)
					} else {
						want204(t, r)
					}
					r = <-issued
					if first == "issuance" {
						s := sessionTokens(t, r)
						e.assertRevokedPair(t, s)
					} else if flow == "otp" {
						wantProblem(t, r, 400, "invalid_code")
					} else {
						wantProblem(t, r, 401, "invalid_credentials")
					}
				})
			}
		}
	}
}

func TestLifecycle_TransitionVsRefresh(t *testing.T) {
	for _, transition := range []string{"delete", "deactivate"} {
		for _, first := range []string{"refresh", "transition"} {
			t.Run(transition+"/"+first, func(t *testing.T) {
				e := newSignupEnv(t, nil)
				u := newUser(t, e.q)
				a, b := e.issue(t, u, "A"), e.issue(t, u, "B")
				var p rightsProof
				if transition == "delete" {
					var r response
					p, r = e.rightsStart(t, "delete", u.Email)
					wantStatus(t, r, 202)
				}
				change := func() response {
					if transition == "delete" {
						return e.rightsComplete(t, p)
					}
					return e.deactivate(t, a.AccessToken, 0)
				}
				changed, ref := make(chan response, 1), make(chan response, 1)
				if first == "refresh" {
					tx, err := e.d.Pool.Begin(context.Background())
					if err != nil {
						t.Fatal(err)
					}
					defer tx.Rollback(context.Background())
					if _, err := sqlc.New(tx).LockActingSessionForUpdate(context.Background(), sqlc.LockActingSessionForUpdateParams{ID: b.SessionID, UserID: u.ID}); err != nil {
						t.Fatal(err)
					}
					go func() { ref <- e.refresh(t, b.RefreshToken) }()
					waitForLockWaiters(t, e, 1)
					go func() { changed <- change() }()
					waitForLockWaiters(t, e, 2)
					if err := tx.Commit(context.Background()); err != nil {
						t.Fatal(err)
					}
					s := sessionTokens(t, <-ref)
					e.assertRevokedPairAfter(t, s, changed, transition)
				} else {
					action := "account.delete.request"
					if transition == "deactivate" {
						action = "account.deactivate"
					}
					release := managementGate(t, e, action)
					go func() { changed <- change() }()
					waitForLockWaiters(t, e, 1)
					go func() { ref <- e.refresh(t, b.RefreshToken) }()
					waitForLockWaiters(t, e, 2)
					release()
					r := <-changed
					if transition == "delete" {
						wantStatus(t, r, 202)
					} else {
						want204(t, r)
					}
					wantUnauthorized(t, <-ref)
				}
				e.assertRevokedPair(t, a)
				e.assertRevokedPair(t, b)
			})
		}
	}
}
func (e *signupEnv) assertRevokedPairAfter(t *testing.T, s session.Issued, ch <-chan response, transition string) {
	t.Helper()
	r := <-ch
	if transition == "delete" {
		wantStatus(t, r, 202)
	} else {
		want204(t, r)
	}
	e.assertRevokedPair(t, s)
}

func TestLifecycle_ExportExpiryAndInvalidation(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	p, r := e.rightsStart(t, "export", u.Email)
	wantStatus(t, r, 202)
	wantStatus(t, e.rightsComplete(t, p), 202)
	e.finishRightsJobs(t)
	wantStatus(t, e.download(t, p), 200)
	mustExec(t, e.d.Pool, `UPDATE account_operations SET download_expires_at=now() WHERE id=$1`, uuid.MustParse(p.id))
	wantProblem(t, e.download(t, p), 410, "export_expired")
	e.finishRightsJobs(t)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM account_operations WHERE id=$1 AND artifact_ciphertext IS NOT NULL`, uuid.MustParse(p.id)) != 0 {
		t.Fatal("expired artifact retained")
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action='account.export.expire' AND target_user_id=$1 AND metadata->>'operation_id'=$2`, u.ID, p.id) != 1 {
		t.Fatal("artifact expiry not audited exactly once")
	}
	wantMetric(t, e.metrics, `account_jobs_total{job="export",result="ready"}`, 1)
	wantMetric(t, e.metrics, `account_jobs_total{job="export",result="expired"}`, 1)
	bad := p
	bad.cap = "vop_unknown"
	wantProblem(t, e.rightsStatus(t, bad), 404, "not_found")
}

func TestMigrations_LifecycleUpgradeFrom9(t *testing.T) {
	d := pgtest.NewEmpty(t)
	ctx := context.Background()
	if _, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 9)); err != nil {
		t.Fatal(err)
	}
	seedCleanupData(t, d, 50)
	before := tableCounts(t, d)
	r, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 10))
	if err != nil || r.Current != 10 || len(r.Applied) != 1 || before != tableCounts(t, d) {
		t.Fatalf("upgrade: %+v %v", r, err)
	}
}

func TestLifecycle_UnboundSignupDoesNotResurrect(t *testing.T) {
	e := newSignupEnv(t, nil)
	next := newAddress("old-signup")
	code := e.queueCode()
	signup := e.startOTP(t, next)
	wantStatus(t, signup, 202)
	u, pw := e.passwordUser(t)
	s := e.issue(t, u, "A")
	pair, r := e.emailStart(t, s.AccessToken, next)
	wantStatus(t, r, 202)
	want204(t, e.emailComplete(t, s.AccessToken, pair))
	login := e.login(t, next, pw)
	wantStatus(t, login, 200)
	p, r := e.rightsStart(t, "delete", next)
	wantStatus(t, r, 202)
	bad := p
	bad.code = wrongCode(p.code)
	wantProblem(t, e.rightsComplete(t, bad), 400, "invalid_code")
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM otp_challenges WHERE token_hash=$1 AND superseded_at IS NULL`, otp.HashToken(signup.str("challenge_token"))) != 1 {
		t.Fatal("failed deletion invalidated signup")
	}
	wantStatus(t, e.rightsComplete(t, p), 202)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM otp_challenges WHERE token_hash=$1 AND superseded_at IS NOT NULL`, otp.HashToken(signup.str("challenge_token"))) != 1 {
		t.Fatal("accepted deletion did not invalidate old signup")
	}
	e.finishRightsJobs(t)
	// Erasing an old HMAC fence (e.g. after key rotation) cannot restore the superseded code.
	mustExec(t, e.d.Pool, `DELETE FROM erased_addresses`)
	wantProblem(t, e.verify(t, signup.str("challenge_token"), code), 400, "invalid_code")
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM users WHERE email_normalized=$1`, strings.ToLower(next)) != 0 {
		t.Fatal("old unbound signup recreated account")
	}
}

func TestLifecycle_ProofExpiryAfterLockWait(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	p, r := e.rightsStart(t, "delete", u.Email)
	wantStatus(t, r, 202)
	tx, err := e.d.Pool.Begin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	must := func(q string) {
		if _, err := tx.Exec(context.Background(), q, otp.HashToken(p.token)); err != nil {
			t.Fatal(err)
		}
	}
	must(`SELECT id FROM otp_challenges WHERE token_hash=$1 FOR UPDATE`)
	done := make(chan response, 1)
	go func() { done <- e.rightsComplete(t, p) }()
	waitForLockWaiters(t, e, 1)
	must(`UPDATE otp_challenges SET expires_at=clock_timestamp() WHERE token_hash=$1`)
	if err := tx.Commit(context.Background()); err != nil {
		t.Fatal(err)
	}
	wantProblem(t, <-done, 400, "invalid_code")
}

func TestLifecycle_StalePasswordBeforeReactivation(t *testing.T) {
	e := newSignupEnv(t, nil)
	u, pw := e.passwordUser(t)
	a := e.issue(t, u, "A")
	ready, release := make(chan struct{}), make(chan struct{})
	e.hasher.afterVerify.Store(func() { close(ready); <-release })
	done := make(chan response, 1)
	go func() { done <- e.login(t, u.Email, pw) }()
	<-ready
	want204(t, e.deactivate(t, a.AccessToken, 0))
	p, r := e.rightsStart(t, "reactivate", u.Email)
	wantStatus(t, r, 202)
	want204(t, e.rightsComplete(t, p))
	close(release)
	wantProblem(t, <-done, 401, "invalid_credentials")
	e.hasher.afterVerify.Store((func())(nil))
}

func TestLifecycle_ContractErrors(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	s := e.issue(t, u, "A")
	wantUnauthorized(t, e.post(t, pathDeactivate, map[string]any{"confirm": true, "expected_revision": 0}))
	for _, body := range []string{`{}`, `{"confirm":false,"expected_revision":0}`, `{"confirm":true,"expected_revision":null}`} {
		wantProblem(t, e.post(t, pathDeactivate, body, bearer(s.AccessToken)...), 400, "invalid_request")
	}
	for _, action := range []string{"export", "delete", "reactivate"} {
		p, r := e.rightsStart(t, action, u.Email)
		wantStatus(t, r, 202)
		start := "/v1/account-rights/" + action + "/start"
		wantProblem(t, e.post(t, start, `{}`), 400, "invalid_request")
		wantProblem(t, e.post(t, start, map[string]string{"email": "invalid"}), 400, "invalid_email")
		wantProblem(t, e.post(t, start+"?x=1", map[string]string{"email": u.Email}), 400, "invalid_request")
		wantProblem(t, e.post(t, p.completePath(), `{}`, rightsHeaders(p.cap)...), 400, "invalid_request")
		wantProblem(t, e.post(t, p.completePath()+"?x=1", p.body(), rightsHeaders(p.cap)...), 400, "invalid_request")
		bad := p
		bad.cap = "vop_unknown"
		wantProblem(t, e.rightsComplete(t, bad), 404, "not_found")
		// Every route gets an actual, committed OTP rejection; reactivate an active owner is inert.
		bad = p
		bad.code = wrongCode(p.code)
		wantProblem(t, e.rightsComplete(t, bad), 400, "invalid_code")
		for range 4 {
			wantProblem(t, e.rightsComplete(t, bad), 400, "invalid_code")
		}
		wantProblem(t, e.rightsComplete(t, p), 400, "code_attempts_exceeded")
		if action != "reactivate" {
			wantProblem(t, e.get(t, p.statusPath()+"?x=1", rightsHeaders(p.cap)...), 400, "invalid_request")
			wantProblem(t, e.get(t, p.statusPath(), rightsHeaders("vop_bad")...), 404, "not_found")
		}
		if action == "export" {
			wantProblem(t, e.get(t, p.statusPath()+"/download?x=1", rightsHeaders(p.cap)...), 400, "invalid_request")
			wantProblem(t, e.get(t, p.statusPath()+"/download", rightsHeaders("vop_bad")...), 404, "not_found")
		}
	}
}

func TestLifecycle_ContractInternalErrors(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	s := e.issue(t, u, "A")
	var proofs []rightsProof
	for _, action := range []string{"export", "delete", "reactivate"} {
		p, r := e.rightsStart(t, action, u.Email)
		wantStatus(t, r, 202)
		proofs = append(proofs, p)
	}
	mustExec(t, e.d.Pool, `ALTER TABLE account_operations RENAME TO test_missing_operations`)
	defer mustExec(t, e.d.Pool, `ALTER TABLE test_missing_operations RENAME TO account_operations`)
	wantProblem(t, e.deactivate(t, s.AccessToken, 0), 500, "internal_error")
	for _, p := range proofs {
		_, r := e.rightsStart(t, p.action, newUser(t, e.q).Email)
		wantProblem(t, r, 500, "internal_error")
		wantProblem(t, e.rightsComplete(t, p), 500, "internal_error")
		if p.action != "reactivate" {
			wantProblem(t, e.rightsStatus(t, p), 500, "internal_error")
		}
		if p.action == "export" {
			wantProblem(t, e.download(t, p), 500, "internal_error")
		}
	}
}

func TestLifecycle_ContractRateLimits(t *testing.T) {
	t.Run("deactivate", func(t *testing.T) {
		rules := generousRules()
		rules.RequestSession.Limit = 1
		e := newSignupEnv(t, rules)
		avoidMinuteBoundary(t, e)
		s := e.issue(t, newUser(t, e.q), "A")
		wantStatus(t, e.me(t, s.AccessToken), 200)
		wantProblem(t, e.deactivate(t, s.AccessToken, 0), 429, "rate_limited")
	})
	for _, action := range []string{"export", "delete", "reactivate"} {
		t.Run(action, func(t *testing.T) {
			e := newSignupEnv(t, nil)
			p, r := e.rightsStart(t, action, newUser(t, e.q).Email)
			wantStatus(t, r, 202)
			_, r = e.rightsStart(t, action, pickOperationEmail(t, e, p))
			wantProblem(t, r, 429, "rate_limited")
			mustExec(t, e.d.Pool, `UPDATE rate_limit_counters SET count=10000 WHERE key LIKE 'rights_operation:%'`)
			// Prime then exceed the operation limit, without hundreds of artificial HTTP calls.
			if p.action != "reactivate" {
				wantStatus(t, e.rightsStatus(t, p), 200)
			} else {
				bad := p
				bad.code = wrongCode(p.code)
				wantProblem(t, e.rightsComplete(t, bad), 400, "invalid_code")
			}
			mustExec(t, e.d.Pool, `UPDATE rate_limit_counters SET count=10000 WHERE key LIKE 'rights_operation:%'`)
			wantProblem(t, e.rightsComplete(t, p), 429, "rate_limited")
			if p.action != "reactivate" {
				wantProblem(t, e.rightsStatus(t, p), 429, "rate_limited")
			}
			if p.action == "export" {
				wantProblem(t, e.download(t, p), 429, "rate_limited")
			}
		})
	}
}
func pickOperationEmail(t *testing.T, e *signupEnv, p rightsProof) string {
	t.Helper()
	var email string
	if err := e.d.Pool.QueryRow(context.Background(), `SELECT email FROM otp_challenges WHERE token_hash=$1`, otp.HashToken(p.token)).Scan(&email); err != nil {
		t.Fatal(err)
	}
	return email
}

func TestLifecycle_ReactivationConflictAndReceiptExpiry(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	mustExec(t, e.d.Pool, `UPDATE users SET status='deactivated' WHERE id=$1`, u.ID)
	p, r := e.rightsStart(t, "reactivate", u.Email)
	wantStatus(t, r, 202)
	mustExec(t, e.d.Pool, `UPDATE users SET status = 'suspended', resume_status = 'active', suspension_reason = 'other', lifecycle_revision=1 WHERE id=$1`, u.ID)
	wantProblem(t, e.rightsComplete(t, p), 409, "lifecycle_conflict")
	d, r := e.rightsStart(t, "delete", u.Email)
	wantStatus(t, r, 202)
	wantStatus(t, e.rightsComplete(t, d), 202)
	mustExec(t, e.d.Pool, `UPDATE account_operations SET expires_at=clock_timestamp() WHERE id=$1`, uuid.MustParse(d.id))
	wantProblem(t, e.rightsStatus(t, d), 404, "not_found")
	e.finishRightsJobs(t)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM users WHERE id=$1`, u.ID) != 0 {
		t.Fatal("expired receipt stopped purge")
	}
}

func TestLifecycle_AuditAndLedgerRetention(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	p, r := e.rightsStart(t, "delete", u.Email)
	wantStatus(t, r, 202)
	wantStatus(t, e.rightsComplete(t, p), 202)
	e.finishRightsJobs(t)
	mustExec(t, e.d.Pool, `UPDATE deletion_ledger SET retain_until=now()-interval '1 second' WHERE user_id=$1`, u.ID)
	mustExec(t, e.d.Pool, `INSERT INTO audit_events(action,outcome,occurred_at) VALUES('test.old','success',now()-interval '181 days'),('test.recent','success',now()-interval '179 days')`)
	e.finishRightsJobs(t)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM deletion_ledger WHERE user_id=$1`, u.ID) != 0 || rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action='test.old'`) != 0 || rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action='test.recent'`) != 1 {
		t.Fatal("retention bounds")
	}
}

func TestLifecycle_SecondExportRequiresNewWindow(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	p, r := e.rightsStart(t, "export", u.Email)
	wantStatus(t, r, 202)
	wantStatus(t, e.rightsComplete(t, p), 202)
	mustExec(t, e.d.Pool, `UPDATE otp_cooldowns SET last_issued_at=now()-interval '2 minutes' WHERE purpose='account_export'`)
	p, r = e.rightsStart(t, "export", u.Email)
	wantStatus(t, r, 202)
	wantProblem(t, e.rightsComplete(t, p), 409, "lifecycle_conflict")
}
