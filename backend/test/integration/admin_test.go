//go:build integration

package integration

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"net/http"
	"net/url"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/migrate"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
)

// TRD 06: RBAC and user administration through the real router and PostgreSQL.

const pathAdminUsers = "/v1/admin/users"

func adminPath(id uuid.UUID, suffix string) string {
	return pathAdminUsers + "/" + id.String() + suffix
}

// withRole creates an active, verified account and gives it role by fixture SQL.
func (e *signupEnv) withRole(t *testing.T, role string) sqlc.User {
	t.Helper()
	u := newUser(t, e.q)
	if role != "user" {
		mustExec(t, e.d.Pool, `UPDATE users SET role = $2 WHERE id = $1`, u.ID, role)
		u.Role = role
	}
	return u
}

func (e *signupEnv) superAdmin(t *testing.T) sqlc.User { return e.withRole(t, "super_admin") }

// staff returns an account with role and a live session for it.
func (e *signupEnv) staff(t *testing.T, role string) (sqlc.User, session.Issued) {
	t.Helper()
	u := e.withRole(t, role)
	return u, e.issue(t, u, "Admin console")
}

func (e *signupEnv) userRow(t *testing.T, id uuid.UUID) sqlc.User {
	t.Helper()
	u, err := e.q.GetUserByID(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	return u
}

func (e *signupEnv) adminGet(t *testing.T, access, path string) response {
	t.Helper()
	return e.send(t, http.MethodGet, path, "", bearer(access)...)
}

func (e *signupEnv) adminTransition(t *testing.T, access string, target uuid.UUID, action, reason string, rev int64) response {
	t.Helper()
	return e.post(t, adminPath(target, "/lifecycle-transitions"), map[string]any{
		"action": action, "reason_code": reason, "ticket_ref": nil, "expected_lifecycle_revision": rev}, bearer(access)...)
}

func (e *signupEnv) suspend(t *testing.T, access string, target uuid.UUID) response {
	t.Helper()
	return e.adminTransition(t, access, target, "suspend", "abuse", e.userRow(t, target).LifecycleRevision)
}

func (e *signupEnv) reinstate(t *testing.T, access string, target uuid.UUID) response {
	t.Helper()
	return e.adminTransition(t, access, target, "reinstate", "appeal_upheld", e.userRow(t, target).LifecycleRevision)
}

func (e *signupEnv) adminRole(t *testing.T, access string, target uuid.UUID, role string, rev int64) response {
	t.Helper()
	return e.send(t, http.MethodPut, adminPath(target, "/role"), map[string]any{
		"role": role, "reason_code": "staffing_change", "ticket_ref": nil, "expected_role_revision": rev}, bearer(access)...)
}

func (e *signupEnv) setRole(t *testing.T, access string, target uuid.UUID, role string) response {
	t.Helper()
	return e.adminRole(t, access, target, role, e.userRow(t, target).RoleRevision)
}

func (e *signupEnv) adminRevoke(t *testing.T, access string, target uuid.UUID, sid *uuid.UUID) response {
	t.Helper()
	var s any
	if sid != nil {
		s = sid.String()
	}
	return e.post(t, adminPath(target, "/session-revocations"), map[string]any{
		"session_id": s, "reason_code": "security_review", "ticket_ref": nil}, bearer(access)...)
}

// guardKey mirrors accounts.LockSuperAdminGuard's advisory key.
func guardKey() int64 {
	h := sha256.Sum256([]byte("veea:rbac:super_admin_guard"))
	return int64(binary.BigEndian.Uint64(h[:8]))
}

// holdGuard takes L2s in a test transaction, so concurrent guarded transactions queue behind it
// and waitForLockWaiters can observe them before release.
func (e *signupEnv) holdGuard(t *testing.T) func() {
	t.Helper()
	ctx := context.Background()
	tx, err := e.d.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, guardKey()); err != nil {
		t.Fatal(err)
	}
	done := false
	release := func() {
		if !done {
			done = true
			if err := tx.Commit(ctx); err != nil {
				t.Error(err)
			}
		}
	}
	t.Cleanup(release)
	return release
}

func (e *signupEnv) activeSuperAdmins(t *testing.T) int64 {
	t.Helper()
	n, err := e.q.CountActiveSuperAdmins(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func strs(v any) []string {
	var out []string
	for _, x := range v.([]any) {
		out = append(out, x.(string))
	}
	return out
}

// =============================================================================================
// Authorization matrix (TRD 06 §3)
// =============================================================================================

// matrixWant is the approved matrix: Admins view and manage User accounts only; Super Admins act
// on every other account; the only self action besides viewing is stepping down to user.
func matrixWant(actorRole, kind, op string) (int, string) {
	if actorRole == "user" {
		return 403, "forbidden"
	}
	allowed := false
	switch actorRole {
	case "admin":
		allowed = kind == "user" && op != "role"
	case "super_admin":
		allowed = kind != "self" || op == "view"
	}
	if allowed {
		return 200, ""
	}
	return 403, "target_not_permitted"
}

func TestAdmin_AuthorizationMatrix(t *testing.T) {
	ops := []string{"view", "sessions_view", "sessions_revoke", "suspend", "reinstate", "role"}
	for _, actorRole := range []string{"user", "admin", "super_admin"} {
		t.Run(actorRole, func(t *testing.T) {
			e := newSignupEnv(t, nil)
			actor, s := e.staff(t, actorRole)
			e.superAdmin(t) // another active Super Admin, so no guard decides a cell here
			for _, kind := range []string{"self", "user", "admin", "super_admin"} {
				for _, op := range ops {
					t.Run(kind+"/"+op, func(t *testing.T) {
						target := actor
						if kind != "self" {
							target = e.withRole(t, kind)
						}
						victim := e.issue(t, target, "Victim")
						before := e.userRow(t, target.ID)
						var r response
						switch op {
						case "view":
							r = e.adminGet(t, s.AccessToken, adminPath(target.ID, ""))
						case "sessions_view":
							r = e.adminGet(t, s.AccessToken, adminPath(target.ID, "/sessions"))
						case "sessions_revoke":
							r = e.adminRevoke(t, s.AccessToken, target.ID, &victim.SessionID)
						case "suspend":
							r = e.suspend(t, s.AccessToken, target.ID)
						case "reinstate":
							r = e.reinstate(t, s.AccessToken, target.ID) // active target: end state holds
						case "role":
							role := map[string]string{"self": "admin", "user": "admin", "admin": "user", "super_admin": "admin"}[kind]
							r = e.adminRole(t, s.AccessToken, target.ID, role, 0)
						}
						status, code := matrixWant(actorRole, kind, op)
						if status != 200 {
							wantProblem(t, r, status, code)
							after := e.userRow(t, target.ID)
							if after.Status != before.Status || after.Role != before.Role || after.RoleRevision != before.RoleRevision ||
								after.LifecycleRevision != before.LifecycleRevision || e.sessionRow(t, victim.SessionID).revoked {
								t.Fatal("a refused admin request changed the target")
							}
							return
						}
						wantStatus(t, r, 200)
						switch op {
						case "view":
							want := []string{"suspend", "change_role", "view_sessions", "revoke_sessions", "manage_plan"}
							if actorRole == "admin" {
								want = []string{"suspend", "view_sessions", "revoke_sessions", "manage_plan"}
							}
							if kind == "self" {
								want = []string{"change_role"}
								if !slices.Equal(strs(r.body["assignable_roles"]), []string{"user"}) {
									t.Fatalf("self assignable roles %v", r.body["assignable_roles"])
								}
							}
							if got := strs(r.body["allowed_actions"]); !slices.Equal(got, want) {
								t.Fatalf("allowed_actions %v, want %v", got, want)
							}
						case "sessions_revoke", "suspend":
							e.assertRevokedPair(t, victim)
						case "role":
							if accountsRank(r.str("role")) > accountsRank(before.Role) {
								e.assertRevokedPair(t, victim) // promotion revokes every target session
							} else {
								wantStatus(t, e.me(t, victim.AccessToken), 200) // demotion keeps them
							}
						}
					})
				}
			}
			r := e.adminGet(t, s.AccessToken, pathAdminUsers+"?limit=100")
			switch actorRole {
			case "user":
				wantProblem(t, r, 403, "forbidden")
			case "admin":
				wantStatus(t, r, 200)
				for _, it := range r.body["items"].([]any) {
					if it.(map[string]any)["role"] != "user" {
						t.Fatal("an Admin listed a staff account")
					}
				}
				wantProblem(t, e.adminGet(t, s.AccessToken, pathAdminUsers+"?role=admin"), 403, "target_not_permitted")
			case "super_admin":
				wantStatus(t, r, 200)
				roles := map[string]bool{}
				for _, it := range r.body["items"].([]any) {
					roles[it.(map[string]any)["role"].(string)] = true
				}
				if !roles["user"] || !roles["admin"] || !roles["super_admin"] {
					t.Fatalf("a Super Admin sees every role, got %v", roles)
				}
			}
		})
	}
}

func accountsRank(role string) int {
	return map[string]int{"user": 1, "admin": 2, "super_admin": 3}[role]
}

// =============================================================================================
// Role changes and existing sessions (TRD 06 §5.1)
// =============================================================================================

func TestAdmin_RoleChangeAndExistingSessions(t *testing.T) {
	e := newSignupEnv(t, nil)
	_, sa := e.staff(t, "super_admin")
	u, pw := e.passwordUser(t)
	a, b := e.issue(t, u, "A"), e.issue(t, u, "B")

	t.Run("promotion revokes every target session; fresh sign-in carries the role", func(t *testing.T) {
		r := e.adminRole(t, sa.AccessToken, u.ID, "admin", 0)
		wantStatus(t, r, 200)
		if r.str("role") != "admin" || r.body["role_revision"].(float64) != 1 || r.body["sessions"].(map[string]any)["live_count"].(float64) != 0 {
			t.Fatalf("promotion view: %s", r.raw)
		}
		e.assertRevokedPair(t, a)
		e.assertRevokedPair(t, b)
		if e.sessionRow(t, a.SessionID).reason != "role_change" {
			t.Fatal("promotion must revoke with reason role_change")
		}
		fresh := sessionTokens(t, e.login(t, u.Email, pw))
		wantStatus(t, e.adminGet(t, fresh.AccessToken, pathAdminUsers), 200)
		// Retried promotion after a lost response: the end state holds, nothing more happens.
		wantStatus(t, e.adminRole(t, sa.AccessToken, u.ID, "admin", 0), 200)
		wantStatus(t, e.me(t, fresh.AccessToken), 200)
		if e.userRow(t, u.ID).RoleRevision != 1 {
			t.Fatal("a no-op changed the role revision")
		}
	})

	t.Run("demotion keeps sessions and applies on the next request", func(t *testing.T) {
		c := e.issue(t, u, "C")
		wantStatus(t, e.adminGet(t, c.AccessToken, pathAdminUsers), 200)
		wantStatus(t, e.adminRole(t, sa.AccessToken, u.ID, "user", 1), 200)
		wantStatus(t, e.me(t, c.AccessToken), 200)
		if e.sessionRow(t, c.SessionID).revoked {
			t.Fatal("demotion revoked a session")
		}
		wantProblem(t, e.adminGet(t, c.AccessToken, pathAdminUsers), 403, "forbidden")
		wantStatus(t, e.refresh(t, c.RefreshToken), 200)
	})

	t.Run("stale revision cannot undo a later change (ABA)", func(t *testing.T) {
		// rev 2 now (user). A promotes with 2 -> 3, B demotes 3 -> 4, A's retry with 2 is refused.
		wantStatus(t, e.adminRole(t, sa.AccessToken, u.ID, "admin", 2), 200)
		wantStatus(t, e.adminRole(t, sa.AccessToken, u.ID, "user", 3), 200)
		wantProblem(t, e.adminRole(t, sa.AccessToken, u.ID, "admin", 2), 409, "role_conflict")
		if e.userRow(t, u.ID).Role != "user" {
			t.Fatal("stale retry changed the role")
		}
	})

	t.Run("promotion needs an active target; demotion of a suspended admin is allowed", func(t *testing.T) {
		x := e.withRole(t, "user")
		wantStatus(t, e.suspend(t, sa.AccessToken, x.ID), 200)
		r := e.adminRole(t, sa.AccessToken, x.ID, "admin", 0)
		wantProblem(t, r, 409, "status_conflict")
		if r.str("account_status") != "suspended" {
			t.Fatalf("status_conflict must carry account_status: %s", r.raw)
		}
		y := e.withRole(t, "admin")
		wantStatus(t, e.suspend(t, sa.AccessToken, y.ID), 200)
		wantStatus(t, e.adminRole(t, sa.AccessToken, y.ID, "user", 0), 200)
	})

	t.Run("Super Admin may step down only to user", func(t *testing.T) {
		other, so := e.staff(t, "super_admin")
		wantProblem(t, e.adminRole(t, so.AccessToken, other.ID, "admin", 0), 403, "target_not_permitted")
		wantStatus(t, e.adminRole(t, so.AccessToken, other.ID, "user", 0), 200)
		wantStatus(t, e.me(t, so.AccessToken), 200) // session preserved
		wantProblem(t, e.adminGet(t, so.AccessToken, pathAdminUsers), 403, "forbidden")
	})
}

// A demotion that commits while an admin write waits on the actor's row makes the write fail
// its in-transaction revalidation, so a stale Principal.Role never authorizes a mutation.
func TestAdmin_ActorRevalidationInsideTheTransaction(t *testing.T) {
	for _, change := range []string{"demoted", "suspended", "logged out"} {
		t.Run(change, func(t *testing.T) {
			e := newSignupEnv(t, nil)
			e.superAdmin(t)
			admin, s := e.staff(t, "admin")
			target := e.withRole(t, "user")
			victim := e.issue(t, target, "Victim")
			ctx := context.Background()
			tx, err := e.d.Pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback(ctx)
			if _, err := sqlc.New(tx).LockUserForNoKeyUpdate(ctx, admin.ID); err != nil {
				t.Fatal(err)
			}
			got := make(chan response, 1)
			go func() { got <- e.suspend(t, s.AccessToken, target.ID) }() // authenticated as admin
			waitForLockWaiters(t, e, 1)
			switch change {
			case "demoted":
				_, err = tx.Exec(ctx, `UPDATE users SET role = 'user' WHERE id = $1`, admin.ID)
			case "suspended":
				_, err = tx.Exec(ctx, `UPDATE users SET status = 'suspended', resume_status = 'active', suspension_reason = 'other' WHERE id = $1`, admin.ID)
			case "logged out":
				_, err = tx.Exec(ctx, `UPDATE sessions SET revoked_at = now(), revoked_reason = 'logout' WHERE id = $1`, s.SessionID)
			}
			if err != nil {
				t.Fatal(err)
			}
			if err := tx.Commit(ctx); err != nil {
				t.Fatal(err)
			}
			r := <-got
			if change == "demoted" {
				wantProblem(t, r, 403, "forbidden")
			} else {
				wantUnauthorized(t, r)
			}
			if e.userRow(t, target.ID).Status != "active" || e.sessionRow(t, victim.SessionID).revoked {
				t.Fatal("a write by a no-longer-authorized actor committed")
			}
		})
	}
}

// =============================================================================================
// Suspension and reinstatement (TRD 06 §5.2, §5.3)
// =============================================================================================

func TestAdmin_SuspendReinstate(t *testing.T) {
	e := newSignupEnv(t, nil)
	admin, s := e.staff(t, "admin")
	u, pw := e.passwordUser(t)
	a := e.issue(t, u, "A")
	// A pre-suspension OTP login proof, to show reinstatement does not revive it.
	code := e.queueCode()
	oldProof := e.otpLoginStart(t, u.Email).str("challenge_token")
	// A pending export is cancelled by the suspension.
	exp, r := e.rightsStart(t, "export", u.Email)
	wantStatus(t, r, 202)
	wantStatus(t, e.rightsComplete(t, exp), 202)

	r = e.post(t, adminPath(u.ID, "/lifecycle-transitions"), map[string]any{"action": "suspend", "reason_code": "abuse",
		"ticket_ref": "SUP-1042", "expected_lifecycle_revision": e.userRow(t, u.ID).LifecycleRevision}, bearer(s.AccessToken)...)
	wantStatus(t, r, 200)
	susp := r.body["suspension"].(map[string]any)
	if r.str("status") != "suspended" || susp["resume_status"] != "active" || susp["reason_code"] != "abuse" ||
		susp["ticket_ref"] != "SUP-1042" || susp["suspended_by_user_id"] != admin.ID.String() || !slices.Equal(strs(r.body["allowed_actions"]), []string{"reinstate", "view_sessions", "revoke_sessions", "manage_plan"}) {
		t.Fatalf("suspension view: %s", r.raw)
	}
	e.assertRevokedPair(t, a)
	if e.sessionRow(t, a.SessionID).reason != "account_suspended" {
		t.Fatal("suspension must revoke with account_suspended")
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM account_operations WHERE id = $1 AND state = 'canceled'`, exp.id) != 1 ||
		rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'account.export.cancel' AND actor_user_id = $1`, admin.ID) != 1 {
		t.Fatal("suspension must cancel the pending export, with the admin as actor")
	}
	if e.login(t, u.Email, pw).status == 200 {
		t.Fatal("a suspended account signed in")
	}
	if _, err := e.worker.RunOnce(context.Background()); err != nil { // drain earlier mail
		t.Fatal(err)
	}
	sent := len(e.fake.Sent())
	e.expireCooldownForPurpose(t, "login", u.Email)
	wantStatus(t, e.otpLoginStart(t, u.Email), 202)
	if _, err := e.worker.RunOnce(context.Background()); err != nil || len(e.fake.Sent()) != sent {
		t.Fatal("a suspended account was sent a login code")
	}
	// The owner keeps export and deletion rights by mailbox proof, but cannot self-reactivate.
	e.expireCooldownForPurpose(t, "account_export", u.Email)
	// Outside TRD 04's one-export-per-24-hours window, so only the suspension decides.
	mustExec(t, e.d.Pool, `UPDATE account_operations SET accepted_at = accepted_at - interval '25 hours' WHERE id = $1`, exp.id)
	exp2, r := e.rightsStart(t, "export", u.Email)
	wantStatus(t, r, 202)
	wantStatus(t, e.rightsComplete(t, exp2), 202)
	react, r := e.rightsStart(t, "reactivate", u.Email)
	wantStatus(t, r, 202)
	wantProblem(t, e.rightsComplete(t, react), 400, "invalid_code")

	// Retried suspension: the end state holds, no new event.
	before := rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'admin.user.suspend'`)
	wantStatus(t, e.adminTransition(t, s.AccessToken, u.ID, "suspend", "abuse", 0), 200)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'admin.user.suspend'`) != before {
		t.Fatal("a no-op suspension wrote an event")
	}
	// Reinstatement with a stale revision is refused; with the current one it restores active.
	rev := e.userRow(t, u.ID).LifecycleRevision
	wantProblem(t, e.adminTransition(t, s.AccessToken, u.ID, "reinstate", "appeal_upheld", rev-1), 409, "lifecycle_conflict")
	r = e.adminTransition(t, s.AccessToken, u.ID, "reinstate", "appeal_upheld", rev)
	wantStatus(t, r, 200)
	if r.str("status") != "active" || r.body["suspension"] != nil {
		t.Fatalf("reinstated view: %s", r.raw)
	}
	row := e.userRow(t, u.ID)
	if row.ResumeStatus != nil || row.SuspensionReason != nil || row.SuspendedBy != nil || row.LifecycleRevision != rev+1 {
		t.Fatal("reinstatement must clear the saved suspension and move the revision on")
	}
	e.assertRevokedPair(t, a) // old sessions are never revived
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM account_operations WHERE id = $1 AND state = 'canceled'`, exp2.id) != 1 {
		t.Fatal("an export made while suspended must be cancelled by reinstatement")
	}
	if r := e.otpLoginVerify(t, oldProof, code); r.status == 200 {
		t.Fatal("a pre-suspension login proof was revived")
	}
	wantStatus(t, e.login(t, u.Email, pw), 200)

	t.Run("deactivated owner resumes deactivated", func(t *testing.T) {
		d := newUser(t, e.q)
		ds := e.issue(t, d, "D")
		want204(t, e.deactivate(t, ds.AccessToken, 0))
		r := e.suspend(t, s.AccessToken, d.ID)
		wantStatus(t, r, 200)
		if r.body["suspension"].(map[string]any)["resume_status"] != "deactivated" {
			t.Fatalf("resume status: %s", r.raw)
		}
		r = e.reinstate(t, s.AccessToken, d.ID)
		wantStatus(t, r, 200)
		if r.str("status") != "deactivated" {
			t.Fatal("reinstatement must restore exactly the interrupted state")
		}
		p, pr := e.rightsStart(t, "reactivate", d.Email)
		wantStatus(t, pr, 202)
		want204(t, e.rightsComplete(t, p)) // the owner still reactivates by mailbox, without a session
	})
}

// =============================================================================================
// Pending deletion (TRD 06 §5.4)
// =============================================================================================

func TestAdmin_PendingDeletionTargets(t *testing.T) {
	e := newSignupEnv(t, nil)
	_, sa := e.staff(t, "super_admin")
	e.superAdmin(t)
	for _, from := range []string{"active", "suspended"} {
		t.Run(from, func(t *testing.T) {
			u := e.withRole(t, "admin")
			if from == "suspended" {
				wantStatus(t, e.suspend(t, sa.AccessToken, u.ID), 200)
			}
			p, r := e.rightsStart(t, "delete", u.Email)
			wantStatus(t, r, 202)
			wantStatus(t, e.rightsComplete(t, p), 202)
			row := e.userRow(t, u.ID)
			if row.Status != "pending_deletion" || row.ResumeStatus != nil || row.SuspensionReason != nil {
				t.Fatal("deletion acceptance must clear a saved suspension")
			}
			r = e.adminGet(t, sa.AccessToken, adminPath(u.ID, ""))
			wantStatus(t, r, 200)
			if r.body["pending_deletion"].(map[string]any)["accepted_at"] == nil ||
				!slices.Equal(strs(r.body["allowed_actions"]), []string{"view_sessions", "revoke_sessions"}) || len(strs2(r.body["assignable_roles"])) != 0 {
				t.Fatalf("pending deletion view: %s", r.raw)
			}
			for _, call := range []response{
				e.adminTransition(t, sa.AccessToken, u.ID, "suspend", "abuse", row.LifecycleRevision),
				e.adminTransition(t, sa.AccessToken, u.ID, "reinstate", "appeal_upheld", row.LifecycleRevision),
				e.adminRole(t, sa.AccessToken, u.ID, "user", row.RoleRevision),
				e.adminRole(t, sa.AccessToken, u.ID, "super_admin", row.RoleRevision),
			} {
				wantProblem(t, call, 409, "status_conflict")
				if call.str("account_status") != "pending_deletion" {
					t.Fatalf("account_status: %s", call.raw)
				}
			}
			r = e.adminRevoke(t, sa.AccessToken, u.ID, nil)
			wantStatus(t, r, 200)
			if r.body["revoked_sessions"].(float64) != 0 {
				t.Fatal("a pending deletion has no live session to revoke")
			}
			after := e.userRow(t, u.ID)
			if after.Status != "pending_deletion" || after.Role != "admin" || after.LifecycleRevision != row.LifecycleRevision {
				t.Fatal("a refused mutation changed the pending deletion")
			}
		})
	}
	t.Run("purged target is 404", func(t *testing.T) {
		e.finishRightsJobs(t)
		var id uuid.UUID
		if err := e.d.Pool.QueryRow(context.Background(), `SELECT user_id FROM deletion_ledger WHERE completed_at IS NOT NULL LIMIT 1`).Scan(&id); err != nil {
			t.Fatal(err)
		}
		wantProblem(t, e.adminGet(t, sa.AccessToken, adminPath(id, "")), 404, "not_found")
		wantProblem(t, e.adminGet(t, sa.AccessToken, adminPath(id, "/sessions")), 404, "not_found")
		wantProblem(t, e.adminRevoke(t, sa.AccessToken, id, nil), 404, "not_found")
		wantProblem(t, e.adminTransition(t, sa.AccessToken, id, "suspend", "abuse", 0), 404, "not_found")
		wantProblem(t, e.adminRole(t, sa.AccessToken, id, "admin", 0), 404, "not_found")
	})
}

func strs2(v any) []any {
	out, _ := v.([]any)
	return out
}

// =============================================================================================
// Session revocation and target session list (TRD 06 §6.5)
// =============================================================================================

func TestAdmin_SessionRevocation(t *testing.T) {
	e := newSignupEnv(t, nil)
	_, s := e.staff(t, "admin")
	u, pw := e.passwordUser(t)
	a, b := e.issue(t, u, "A"), e.issue(t, u, "B")
	foreign := e.issue(t, newUser(t, e.q), "Foreign")

	r := e.adminGet(t, s.AccessToken, adminPath(u.ID, "/sessions"))
	wantStatus(t, r, 200)
	rows := r.body["sessions"].([]any)
	if len(rows) != 2 {
		t.Fatalf("target sessions: %s", r.raw)
	}
	for _, row := range rows {
		if len(row.(map[string]any)) != 7 {
			t.Fatalf("session projection leaked or omitted fields: %v", row)
		}
	}
	f, n := e.adminRevoke(t, s.AccessToken, u.ID, &foreign.SessionID), e.adminRevoke(t, s.AccessToken, u.ID, ptr(uuid.New()))
	wantProblem(t, f, 404, "not_found")
	wantProblem(t, n, 404, "not_found")
	if withoutRequestID(f) != withoutRequestID(n) {
		t.Fatal("foreign and unknown session IDs are distinguishable")
	}
	wantStatus(t, e.me(t, foreign.AccessToken), 200)

	r = e.adminRevoke(t, s.AccessToken, u.ID, &a.SessionID)
	wantStatus(t, r, 200)
	if r.body["revoked_sessions"].(float64) != 1 || e.sessionRow(t, a.SessionID).reason != "admin_revoked" {
		t.Fatalf("one revocation: %s", r.raw)
	}
	e.assertRevokedPair(t, a)
	wantStatus(t, e.me(t, b.AccessToken), 200)
	events := rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'admin.sessions.revoke'`)
	r = e.adminRevoke(t, s.AccessToken, u.ID, &a.SessionID) // retry after a lost response
	wantStatus(t, r, 200)
	if r.body["revoked_sessions"].(float64) != 0 || rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'admin.sessions.revoke'`) != events {
		t.Fatal("a retained revoked row must be a silent no-op")
	}
	r = e.adminRevoke(t, s.AccessToken, u.ID, nil)
	wantStatus(t, r, 200)
	if r.body["revoked_sessions"].(float64) != 1 {
		t.Fatalf("all revocation: %s", r.raw)
	}
	e.assertRevokedPair(t, b)
	wantStatus(t, e.me(t, s.AccessToken), 200)  // the actor's own session is untouched
	wantStatus(t, e.login(t, u.Email, pw), 200) // revocation never blocks a later sign-in
	for _, body := range []string{`{"session_id":"nope","reason_code":"other","ticket_ref":null}`,
		`{"session_id":null,"reason_code":"abuse","ticket_ref":null}`, `{"session_id":null,"reason_code":"other","ticket_ref":"has space"}`,
		`{"session_id":null,"reason_code":"other","ticket_ref":"vat_x"}`, `{"session_id":null,"reason_code":"other"}`} {
		wantProblem(t, e.post(t, adminPath(u.ID, "/session-revocations"), body, bearer(s.AccessToken)...), 400, "invalid_request")
	}
}

// =============================================================================================
// List, search and pagination (TRD 06 §6.3)
// =============================================================================================

func (e *signupEnv) userWithEmail(t *testing.T, email string) sqlc.User {
	t.Helper()
	now := time.Now()
	u, err := e.q.InsertUserIfAbsent(context.Background(), sqlc.InsertUserIfAbsentParams{
		ID: newID(), Email: email, EmailNormalized: strings.ToLower(email), EmailVerifiedAt: &now})
	if err != nil {
		t.Fatal(err)
	}
	return u
}

func TestAdmin_ListSearchPagination(t *testing.T) {
	e := newSignupEnv(t, nil)
	sa, s := e.staff(t, "super_admin")
	mustExec(t, e.d.Pool, `UPDATE users SET created_at = '2026-01-01T00:00:00Z' WHERE id = $1`, sa.ID)
	var tied []string
	for range 5 {
		u := newUser(t, e.q)
		tied = append(tied, u.ID.String())
		mustExec(t, e.d.Pool, `UPDATE users SET created_at = '2026-06-01T00:00:00Z' WHERE id = $1`, u.ID)
	}
	sort.Sort(sort.Reverse(sort.StringSlice(tied)))
	// Keyset pages: ties resolved by id descending, no overlap, nothing skipped.
	var seen []string
	next := ""
	for page := 0; ; page++ {
		path := pathAdminUsers + "?limit=2"
		if next != "" {
			path += "&page_token=" + next
		}
		r := e.adminGet(t, s.AccessToken, path)
		wantStatus(t, r, 200)
		for _, it := range r.body["items"].([]any) {
			seen = append(seen, it.(map[string]any)["id"].(string))
		}
		if r.body["next_page_token"] == nil {
			break
		}
		next = r.str("next_page_token")
		if page > 10 {
			t.Fatal("pagination did not end")
		}
	}
	if len(seen) != 6 || !slices.Equal(seen[:5], tied) || seen[5] != sa.ID.String() {
		t.Fatalf("pages: %v, want %v then the Super Admin", seen, tied)
	}
	first := e.adminGet(t, s.AccessToken, pathAdminUsers+"?limit=2")
	tok := first.str("next_page_token")
	wantProblem(t, e.adminGet(t, s.AccessToken, pathAdminUsers+"?limit=2&status=active&page_token="+tok), 400, "invalid_request")
	wantProblem(t, e.adminGet(t, s.AccessToken, pathAdminUsers+"?page_token=a1."+strings.Repeat("A", 43)), 400, "invalid_request")

	under := e.userWithEmail(t, "under_score@example.test")
	e.userWithEmail(t, "underXscore@example.test")
	pct := e.userWithEmail(t, "pct%sign@example.test")
	e.userWithEmail(t, "pctAsign@example.test")
	for prefix, want := range map[string]string{"UNDER_s": under.ID.String(), "pct%": pct.ID.String()} {
		r := e.adminGet(t, s.AccessToken, pathAdminUsers+"?email_prefix="+url.QueryEscape(prefix))
		wantStatus(t, r, 200)
		items := r.body["items"].([]any)
		if len(items) != 1 || items[0].(map[string]any)["id"] != want {
			t.Fatalf("prefix %q is literal: %s", prefix, r.raw)
		}
	}
	r := e.adminGet(t, s.AccessToken, pathAdminUsers+"?email="+url.QueryEscape("  Under_Score@EXAMPLE.test "))
	wantStatus(t, r, 200)
	if items := r.body["items"].([]any); len(items) != 1 || items[0].(map[string]any)["id"] != under.ID.String() {
		t.Fatalf("exact email: %s", r.raw)
	}
	wantProblem(t, e.adminGet(t, s.AccessToken, pathAdminUsers+"?email=not-an-email"), 400, "invalid_email")
	for _, q := range []string{"?email_prefix=ab", "?email=a@b.test&email_prefix=abc", "?limit=0", "?limit=101", "?limit=+5", "?limit=x",
		"?role=root", "?status=deleted", "?other=1", "?limit=1&limit=2", "?page_token="} {
		wantProblem(t, e.adminGet(t, s.AccessToken, pathAdminUsers+q), 400, "invalid_request")
	}
	wantStatus(t, e.adminGet(t, s.AccessToken, pathAdminUsers+"?role=user&status=active&limit=100"), 200)
	// Search audit: filter names only, never the text.
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'admin.user.search'
		AND (metadata::text ILIKE '%under%' OR metadata::text ILIKE '%pct%' OR metadata::text ILIKE '%example%')`) != 0 {
		t.Fatal("search text reached audit metadata")
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM audit_events WHERE action = 'admin.user.search' AND metadata->>'filters' = 'email' AND email_hmac IS NOT NULL`) != 1 {
		t.Fatal("an exact email search records only the email HMAC")
	}
}

// =============================================================================================
// Detail projection (TRD 06 §6.4, R8)
// =============================================================================================

func TestAdmin_DetailProjection(t *testing.T) {
	e := newSignupEnv(t, nil)
	_, s := e.staff(t, "admin")
	u, _ := e.passwordUser(t)
	e.issue(t, u, "Phone")
	mustExec(t, e.d.Pool, `UPDATE sessions SET user_agent = 'SecretAgent/1.0', created_ip = '203.0.113.9', last_seen_ip = '203.0.113.9' WHERE user_id = $1`, u.ID)
	r := e.adminGet(t, s.AccessToken, adminPath(u.ID, ""))
	wantStatus(t, r, 200)
	var keys []string
	for k := range r.body {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	want := []string{"allowed_actions", "assignable_roles", "created_at", "display_name", "email", "email_verified_at", "entitlement_revision",
		"has_password", "id", "lifecycle_revision", "password_changed_at", "pending_deletion", "plan", "plan_expires_at", "preferred_language",
		"role", "role_changed_at", "role_revision", "sessions", "state_changed_at", "status", "suspension", "time_zone"}
	if !slices.Equal(keys, want) {
		t.Fatalf("detail keys %v", keys)
	}
	for _, bad := range []string{"argon2", "SecretAgent", "203.0.113.9", "hash", "vat_", "vrt_"} {
		if strings.Contains(string(r.raw), bad) {
			t.Fatalf("detail leaked %q", bad)
		}
	}
	if r.body["has_password"] != true || r.body["sessions"].(map[string]any)["live_count"].(float64) != 1 {
		t.Fatalf("detail values: %s", r.raw)
	}
	r = e.adminGet(t, s.AccessToken, adminPath(u.ID, "/sessions"))
	if strings.Contains(string(r.raw), "SecretAgent") || strings.Contains(string(r.raw), "203.0.113.9") {
		t.Fatal("session list leaked client metadata")
	}
}

// =============================================================================================
// Contract errors, rate limits and internal errors
// =============================================================================================

func TestAdmin_ContractErrors(t *testing.T) {
	e := newSignupEnv(t, nil)
	_, s := e.staff(t, "super_admin")
	_, us := e.staff(t, "user")
	u := e.withRole(t, "user")
	paths := []struct{ method, path, body string }{
		{"GET", pathAdminUsers, ""},
		{"GET", adminPath(u.ID, ""), ""},
		{"GET", adminPath(u.ID, "/sessions"), ""},
		{"GET", adminPath(u.ID, "/audit"), ""},
		{"POST", adminPath(u.ID, "/session-revocations"), `{"session_id":null,"reason_code":"other","ticket_ref":null}`},
		{"POST", adminPath(u.ID, "/lifecycle-transitions"), `{"action":"suspend","reason_code":"other","ticket_ref":null,"expected_lifecycle_revision":0}`},
		{"PUT", adminPath(u.ID, "/role"), `{"role":"admin","reason_code":"other","ticket_ref":null,"expected_role_revision":0}`},
	}
	for _, p := range paths {
		wantProblem(t, e.send(t, p.method, p.path, p.body, bearer(us.AccessToken)...), 403, "forbidden")
		if p.path != pathAdminUsers {
			for _, bad := range []string{"invalid", uuid.Nil.String(), strings.ReplaceAll(u.ID.String(), "-", "")} {
				wantProblem(t, e.send(t, p.method, strings.Replace(p.path, u.ID.String(), bad, 1), p.body, bearer(s.AccessToken)...), 400, "invalid_request")
			}
			wantProblem(t, e.send(t, p.method, p.path+"?x=1", p.body, bearer(s.AccessToken)...), 400, "invalid_request")
			wantProblem(t, e.send(t, p.method, strings.Replace(p.path, u.ID.String(), uuid.NewString(), 1), p.body, bearer(s.AccessToken)...), 404, "not_found")
		}
		if p.method != "GET" {
			wantProblem(t, e.send(t, p.method, p.path, `{}`, bearer(s.AccessToken)...), 400, "invalid_request")
		}
	}
	for _, body := range []string{
		`{"action":"freeze","reason_code":"other","ticket_ref":null,"expected_lifecycle_revision":0}`,
		`{"action":"suspend","reason_code":"appeal_upheld","ticket_ref":null,"expected_lifecycle_revision":0}`,
		`{"action":"suspend","reason_code":"other","ticket_ref":null,"expected_lifecycle_revision":null}`,
		`{"action":"suspend","reason_code":"other","ticket_ref":null,"expected_lifecycle_revision":-1}`,
	} {
		wantProblem(t, e.post(t, adminPath(u.ID, "/lifecycle-transitions"), body, bearer(s.AccessToken)...), 400, "invalid_request")
	}
	for _, body := range []string{
		`{"role":"root","reason_code":"other","ticket_ref":null,"expected_role_revision":0}`,
		`{"role":"admin","reason_code":"abuse","ticket_ref":null,"expected_role_revision":0}`,
	} {
		wantProblem(t, e.send(t, "PUT", adminPath(u.ID, "/role"), body, bearer(s.AccessToken)...), 400, "invalid_request")
	}
}

func TestAdmin_RateLimitsAndInternalErrors(t *testing.T) {
	t.Run("rate limits", func(t *testing.T) {
		e := newSignupEnv(t, nil)
		avoidMinuteBoundary(t, e)
		_, s := e.staff(t, "super_admin")
		u := e.withRole(t, "user")
		victim := e.issue(t, u, "Victim")
		wantStatus(t, e.adminGet(t, s.AccessToken, pathAdminUsers), 200)
		wantStatus(t, e.adminRevoke(t, s.AccessToken, u.ID, ptr(uuid.New())), 404)
		mustExec(t, e.d.Pool, `UPDATE rate_limit_counters SET count = 10000 WHERE key LIKE 'admin_read_user_1m:%' OR key LIKE 'admin_write_user_1m:%'`)
		for _, r := range []response{
			e.adminGet(t, s.AccessToken, pathAdminUsers), e.adminGet(t, s.AccessToken, adminPath(u.ID, "")),
			e.adminGet(t, s.AccessToken, adminPath(u.ID, "/sessions")), e.adminRevoke(t, s.AccessToken, u.ID, nil),
			e.suspend(t, s.AccessToken, u.ID), e.adminRole(t, s.AccessToken, u.ID, "admin", 0),
			e.adminGet(t, s.AccessToken, adminPath(u.ID, "/audit")),
		} {
			wantProblem(t, r, 429, "rate_limited")
		}
		if e.userRow(t, u.ID).Status != "active" || e.userRow(t, u.ID).Role != "user" || e.sessionRow(t, victim.SessionID).revoked {
			t.Fatal("a rate-limited admin request changed state")
		}
	})
	t.Run("internal errors on every route", func(t *testing.T) {
		e := newSignupEnv(t, nil)
		_, s := e.staff(t, "super_admin")
		u := e.withRole(t, "user")
		// Authentication never reads this column; every admin read and write does.
		mustExec(t, e.d.Pool, `ALTER TABLE users RENAME COLUMN state_changed_at TO test_missing_column`)
		defer mustExec(t, e.d.Pool, `ALTER TABLE users RENAME COLUMN test_missing_column TO state_changed_at`)
		for _, r := range []response{
			e.adminGet(t, s.AccessToken, pathAdminUsers), e.adminGet(t, s.AccessToken, adminPath(u.ID, "")),
			e.adminGet(t, s.AccessToken, adminPath(u.ID, "/sessions")), e.adminRevoke(t, s.AccessToken, u.ID, nil),
			e.adminTransition(t, s.AccessToken, u.ID, "suspend", "abuse", 0), e.adminRole(t, s.AccessToken, u.ID, "admin", 0),
			e.adminGet(t, s.AccessToken, adminPath(u.ID, "/audit")),
		} {
			wantProblem(t, r, 500, "internal_error")
		}
	})
}

// =============================================================================================
// Migration 00012
// =============================================================================================

func TestMigrations_RBACUpgradeFrom11(t *testing.T) {
	d := pgtest.NewEmpty(t)
	ctx := context.Background()
	if _, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 11)); err != nil {
		t.Fatal(err)
	}
	seedCleanupData(t, d, 50)
	legacy := newID()
	mustExec(t, d.Pool, `INSERT INTO users (id, email, email_normalized, email_verified_at, status)
		VALUES ($1, 'legacy@example.test', 'legacy@example.test', now(), 'suspended')`, legacy)
	before := tableCounts(t, d)
	r, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 12))
	if err != nil || r.Current != 12 || len(r.Applied) != 1 || before != tableCounts(t, d) {
		t.Fatalf("upgrade: %+v %v", r, err)
	}
	var resume, reason string
	if err := d.Pool.QueryRow(ctx, `SELECT resume_status, suspension_reason FROM users WHERE id = $1`, legacy).Scan(&resume, &reason); err != nil ||
		resume != "active" || reason != "other" {
		t.Fatalf("legacy suspended row not backfilled: %q %q %v", resume, reason, err)
	}
	_, err = d.Pool.Exec(ctx, `UPDATE users SET resume_status = NULL WHERE id = $1`, legacy)
	wantPgError(t, err, pgCheck, "users_suspension_state")
	_, err = d.Pool.Exec(ctx, `UPDATE users SET status = 'active', resume_status = 'active' WHERE id = $1`, legacy)
	wantPgError(t, err, pgCheck, "users_suspension_state")
	_, err = d.Pool.Exec(ctx, `UPDATE users SET suspension_ticket_ref = 'has space' WHERE id = $1`, legacy)
	wantPgError(t, err, pgCheck, "users_suspension_ticket_ref_check")
	q := sqlc.New(d.Pool)
	for _, reason := range []string{"logout", "account_delete", "admin_revoked", "account_suspended", "role_change"} {
		p := sessionParams(legacy)
		if _, err := q.InsertSession(ctx, p); err != nil {
			t.Fatal(err)
		}
		mustExec(t, d.Pool, `UPDATE sessions SET revoked_at = now(), revoked_reason = $2 WHERE id = $1`, p.ID, reason)
	}
	_, err = d.Pool.Exec(ctx, `UPDATE sessions SET revoked_reason = 'invented' WHERE user_id = $1`, legacy)
	wantPgError(t, err, pgCheck, "sessions_revoked_reason_check")
	if _, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 12)); err != nil {
		t.Fatal("replay:", err)
	}
}
