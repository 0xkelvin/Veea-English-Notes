//go:build integration

package integration

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/learning"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/migrate"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/pgtest"
	"github.com/google/uuid"
	"net/http"
	"sync"
	"testing"
	"time"
)

func cartridgeFixture(t *testing.T, id, plan string, v int32, entries ...uuid.UUID) []byte {
	t.Helper()
	d := learning.CartridgeDocument{ID: id, Title: "Synthetic fixture", Version: v, RequiredPlan: plan}
	for _, entry := range entries {
		d.Entries = append(d.Entries, learning.CartridgeEntry{EntryID: entry, Content: json.RawMessage(`{"word":"synthetic","meaning":"fixture only","pronunciation":null,"part_of_speech":"n","source":null,"examples":[],"tags":[]}`)})
	}
	b, err := json.Marshal(d)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
func (e *signupEnv) publishPack(t *testing.T, id, plan string, v int32, entries ...uuid.UUID) []byte {
	t.Helper()
	raw := cartridgeFixture(t, id, plan, v, entries...)
	changed, err := learning.PublishCartridge(context.Background(), e.d.Pool, raw, "FIX-10")
	if err != nil || !changed {
		t.Fatalf("publish %v %v", changed, err)
	}
	return raw
}
func packPath(id string, v int32, suffix string) string {
	return fmt.Sprintf("/v1/cartridges/%s/versions/%d/%s", id, v, suffix)
}
func (d *device) installPack(t *testing.T, id string, v int32, basis map[string]any) response {
	t.Helper()
	return d.e.post(t, packPath(id, v, "install"), basis, bearer(d.access)...)
}
func (d *device) packBasis(t *testing.T) map[string]any {
	st := d.state(t)
	return map[string]any{"epoch": st.Epoch, "capacity_basis": map[string]any{"live_words": st.LiveWords, "content_bytes": st.ContentBytes}}
}

func TestCartridges_AuthorizationAndExpiry(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	s := e.issue(t, u, "fixture")
	e.publishPack(t, "free_fixture", "free", 1, uuid.New())
	e.publishPack(t, "premium_fixture", "premium", 1, uuid.New())
	get := func(path string) response { return e.send(t, http.MethodGet, path, "", bearer(s.AccessToken)...) }
	r := get("/v1/cartridges")
	wantStatus(t, r, 200)
	if len(r.body["cartridges"].([]any)) != 2 {
		t.Fatal("metadata must include both plans")
	}
	wantStatus(t, get(packPath("free_fixture", 1, "content")), 200)
	wantProblem(t, get(packPath("premium_fixture", 1, "content")), 403, "plan_required")
	now := e.dbNow(t)
	e.insertGrant(t, u.ID, now.Add(-time.Hour), now.Add(time.Hour), nil, nil)
	wantStatus(t, get(packPath("premium_fixture", 1, "content")), 200)
	// Move the exclusive end to DB now, rather than sleep/flaky wall-clock timing.
	mustExec(t, e.d.Pool, `UPDATE entitlement_grants SET ends_at = clock_timestamp() WHERE user_id=$1`, u.ID)
	wantProblem(t, get(packPath("premium_fixture", 1, "content")), 403, "plan_required")
	wantProblem(t, e.send(t, http.MethodGet, "/v1/cartridges", ""), 401, "unauthorized")
	wantProblem(t, get(packPath("missing", 1, "content")), 404, "not_found")
	wantProblem(t, get("/v1/cartridges?surprise=1"), 400, "invalid_request")
	wantProblem(t, get("/v1/cartridges/free_fixture/versions/01/content"), 400, "invalid_request")
	mustExec(t, e.d.Pool, `UPDATE users SET status='deactivated' WHERE id=$1`, u.ID)
	wantProblem(t, get(packPath("free_fixture", 1, "content")), 401, "unauthorized")
}

func TestCartridges_RetryUpdateQuotaAndIsolation(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	u := newUser(t, e.q)
	d := e.device(t, u, "installer")
	a, b, c := uuid.New(), uuid.New(), uuid.New()
	e.publishPack(t, "pack", "free", 1, a, b)
	basis := d.packBasis(t)
	r := d.installPack(t, "pack", 1, basis)
	wantStatus(t, r, 200)
	if r.body["added"] != float64(2) {
		t.Fatal(string(r.raw))
	}
	// Lost response: exact retry with stale capacity imports nothing.
	r = d.installPack(t, "pack", 1, basis)
	wantStatus(t, r, 200)
	if r.body["added"] != float64(0) {
		t.Fatal("retry added words")
	}
	aid, bid := learning.CartridgeWordID("pack", a), learning.CartridgeWordID("pack", b)
	ar := rowCount(t, e.d.Pool, `SELECT revision FROM vocabulary_items WHERE user_id=$1 AND id=$2`, u.ID, aid)
	d.mustPush(t, mUpdate(d.next(), aid, int64(ar), map[string]any{"meaning": "owner edit"}))
	br := rowCount(t, e.d.Pool, `SELECT revision FROM vocabulary_items WHERE user_id=$1 AND id=$2`, u.ID, bid)
	d.mustPush(t, mDelete(d.next(), bid, int64(br)))
	// Simulate content-free tombstone cleanup. The install watermark must outlive it.
	mustExec(t, e.d.Pool, `DELETE FROM vocabulary_items WHERE user_id=$1 AND id=$2 AND deleted_at IS NOT NULL`, u.ID, bid)
	e.publishPack(t, "pack", "free", 2, a, b, c)
	r = d.installPack(t, "pack", 2, d.packBasis(t))
	wantStatus(t, r, 200)
	if r.body["added"] != float64(1) {
		t.Fatal(string(r.raw))
	}
	var meaning string
	if err := e.d.Pool.QueryRow(context.Background(), `SELECT meaning FROM vocabulary_items WHERE user_id=$1 AND id=$2`, u.ID, aid).Scan(&meaning); err != nil || meaning != "owner edit" {
		t.Fatalf("edit lost: %s %v", meaning, err)
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM vocabulary_items WHERE user_id=$1 AND id=$2`, u.ID, bid) != 0 {
		t.Fatal("delete resurrected")
	}
	other := e.device(t, newUser(t, e.q), "other")
	r = other.installPack(t, "pack", 2, other.packBasis(t))
	wantStatus(t, r, 200)
	if r.body["added"] != float64(3) {
		t.Fatal("owner state leaked")
	}
	e.publishPack(t, "quota", "free", 1, uuid.New())
	stale := d.packBasis(t)
	mustExec(t, e.d.Pool, `UPDATE learning_sync_heads SET live_words=50000 WHERE user_id=$1`, u.ID)
	wantProblem(t, d.installPack(t, "quota", 1, stale), 409, "capacity_changed")
	wantProblem(t, d.installPack(t, "quota", 1, d.packBasis(t)), 409, "capacity_changed")
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM cartridge_installations WHERE user_id=$1 AND cartridge_id='quota'`, u.ID) != 0 {
		t.Fatal("quota failure advanced watermark")
	}
	mustExec(t, e.d.Pool, `UPDATE learning_sync_heads SET live_words=49999 WHERE user_id=$1`, u.ID)
	wantStatus(t, d.installPack(t, "quota", 1, d.packBasis(t)), 200)
	e.publishPack(t, "premium", "premium", 1, uuid.New())
	wantProblem(t, d.installPack(t, "premium", 1, d.packBasis(t)), 403, "plan_required")
	old := d.packBasis(t)
	mustExec(t, e.d.Pool, `UPDATE learning_sync_heads SET epoch=gen_random_uuid() WHERE user_id=$1`, u.ID)
	wantProblem(t, d.installPack(t, "pack", 2, old), 410, "sync_reset_required")
}

func TestCartridges_ConcurrentInstallAndRollback(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	d := e.device(t, newUser(t, e.q), "one")
	e.publishPack(t, "concurrent", "free", 1, uuid.New())
	p := d.packBasis(t)
	raw, _ := json.Marshal(p)
	var wg sync.WaitGroup
	replies := make(chan response, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			replies <- e.post(t, packPath("concurrent", 1, "install"), string(raw), bearer(d.access)...)
		}()
	}
	wg.Wait()
	close(replies)
	added := float64(0)
	for r := range replies {
		wantStatus(t, r, 200)
		added += r.body["added"].(float64)
	}
	if added != 1 {
		t.Fatal("double install")
	}
	e.publishPack(t, "rollback", "free", 1, uuid.New())
	before := d.state(t)
	mustExec(t, e.d.Pool, `CREATE FUNCTION fail_install() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected'; END $$; CREATE TRIGGER fail_install BEFORE INSERT ON cartridge_installations FOR EACH ROW EXECUTE FUNCTION fail_install()`)
	wantProblem(t, d.installPack(t, "rollback", 1, d.packBasis(t)), 500, "internal_error")
	if after := d.state(t); after.HeadRevision != before.HeadRevision || after.LiveWords != before.LiveWords {
		t.Fatal("import escaped rollback")
	}
	mustExec(t, e.d.Pool, `DROP TRIGGER fail_install ON cartridge_installations`)
	wantStatus(t, d.installPack(t, "rollback", 1, d.packBasis(t)), 200)
}

func TestCartridges_PublicationAndMigration(t *testing.T) {
	d := pgtest.NewEmpty(t)
	ctx := context.Background()
	if _, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 14)); err != nil {
		t.Fatal(err)
	}
	seedCleanupData(t, d, 50)
	before := tableCounts(t, d)
	r, err := migrate.Up(ctx, d.URL, migrationsUpTo(t, 15))
	if err != nil || r.Current != 15 || before != tableCounts(t, d) {
		t.Fatalf("upgrade %+v %v", r, err)
	}
	a := uuid.New()
	raw := cartridgeFixture(t, "pack", "free", 1, a)
	if changed, err := learning.PublishCartridge(ctx, d.Pool, raw, "FIX-10"); err != nil || !changed {
		t.Fatal(err)
	}
	if changed, err := learning.PublishCartridge(ctx, d.Pool, raw, "FIX-10"); err != nil || changed {
		t.Fatal("republish", err)
	}
	if rowCount(t, d.Pool, `SELECT count(*) FROM audit_events WHERE action='cartridge.publish'`) != 1 {
		t.Fatal("duplicate publish audit")
	}
	for name, bad := range map[string][]byte{"missing_old_entry": cartridgeFixture(t, "pack", "free", 2, uuid.New()), "reclassify": cartridgeFixture(t, "pack", "premium", 2, a), "version_gap": cartridgeFixture(t, "pack", "free", 3, a), "duplicate": cartridgeFixture(t, "dup", "free", 1, a, a), "large": make([]byte, learning.MaxCartridgeBytes+1)} {
		t.Run(name, func(t *testing.T) {
			if _, err := learning.PublishCartridge(ctx, d.Pool, bad, "FIX-10"); err == nil {
				t.Fatal("invalid publication accepted")
			}
		})
	}
	if _, err := d.Pool.Exec(ctx, `UPDATE cartridge_versions SET title='changed'`); err == nil {
		t.Fatal("published version mutable")
	}
	if _, err := d.Pool.Exec(ctx, `DELETE FROM cartridge_entries`); err == nil {
		t.Fatal("entry identity mutable")
	}
}

func TestCartridges_ExportPurgeAndNewAccount(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	u := newUser(t, e.q)
	d := e.device(t, u, "installer")
	e.publishPack(t, "owned", "free", 1, uuid.New())
	wantStatus(t, d.installPack(t, "owned", 1, d.packBasis(t)), 200)
	_, raw := e.exportOf(t, u.Email)
	var doc struct {
		Installations []struct {
			ID      string `json:"cartridge_id"`
			Version int    `json:"installed_version"`
		} `json:"cartridge_installations"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil || len(doc.Installations) != 1 || doc.Installations[0].ID != "owned" || doc.Installations[0].Version != 1 {
		t.Fatalf("export installations %v %v", doc, err)
	}
	proof, r := e.rightsStart(t, "delete", u.Email)
	wantStatus(t, r, 202)
	wantStatus(t, e.rightsComplete(t, proof), 202)
	e.finishRightsJobs(t)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM cartridge_installations WHERE user_id=$1`, u.ID) != 0 || rowCount(t, e.d.Pool, `SELECT count(*) FROM users WHERE id=$1`, u.ID) != 0 {
		t.Fatal("purge missed installation state")
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM cartridge_versions WHERE cartridge_id='owned'`) != 1 {
		t.Fatal("shared content purged")
	}
	v := newUser(t, e.q)
	mustExec(t, e.d.Pool, `UPDATE users SET email=$2,email_normalized=$2 WHERE id=$1`, v.ID, u.Email)
	next := e.device(t, v, "new account")
	r = next.installPack(t, "owned", 1, next.packBasis(t))
	wantStatus(t, r, 200)
	if r.body["added"] != float64(1) {
		t.Fatal("new owner inherited deleted receipt")
	}
}

func TestCartridges_ContractErrors(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	s := e.issue(t, u, "reader")
	e.publishPack(t, "contract", "free", 1, uuid.New())
	path := packPath("contract", 1, "install")
	body := map[string]any{"epoch": uuid.New(), "capacity_basis": map[string]any{"live_words": 0, "content_bytes": 0}}
	wantProblem(t, e.post(t, path, body, bearer(s.AccessToken)...), 503, "sync_unavailable")
	e.openSync(t)
	d := e.device(t, u, "installer")
	basis := d.packBasis(t)
	wantProblem(t, e.post(t, path, basis), 401, "unauthorized")
	wantProblem(t, e.send(t, "GET", packPath("contract", 1, "content"), ""), 401, "unauthorized")
	wantProblem(t, d.installPack(t, "unknown", 1, basis), 404, "not_found")
	wantProblem(t, e.post(t, path, `{}`, bearer(d.access)...), 400, "invalid_request")
	wantProblem(t, e.post(t, path, `{"epoch":"`+d.epoch.String()+`","capacity_basis":null}`, bearer(d.access)...), 400, "invalid_request")
	wantProblem(t, e.post(t, path, string(make([]byte, (16<<10)+1)), bearer(d.access)...), 413, "payload_too_large")
	wantStatus(t, d.installPack(t, "contract", 1, basis), 200)
	mustExec(t, e.d.Pool, `UPDATE rate_limit_counters SET count=10000 WHERE key LIKE 'learning_push%'`)
	wantProblem(t, d.installPack(t, "contract", 1, basis), 429, "rate_limited")
	mustExec(t, e.d.Pool, `ALTER TABLE cartridge_versions RENAME TO missing_versions`)
	wantProblem(t, e.send(t, "GET", "/v1/cartridges", "", bearer(s.AccessToken)...), 500, "internal_error")
	wantProblem(t, e.send(t, "GET", packPath("contract", 1, "content"), "", bearer(s.AccessToken)...), 500, "internal_error")
	mustExec(t, e.d.Pool, `ALTER TABLE missing_versions RENAME TO cartridge_versions`)
	// Authentication's common session limiter applies even when sync is closed.
	rules := generousRules()
	rules.RequestSession.Limit = 1
	limited := newSignupEnv(t, rules)
	limited.publishPack(t, "contract", "free", 1, uuid.New())
	for _, p := range []string{"/v1/cartridges", packPath("contract", 1, "content")} {
		token := limited.issue(t, newUser(t, limited.q), "limited").AccessToken
		wantStatus(t, limited.send(t, "GET", p, "", bearer(token)...), 200)
		wantProblem(t, limited.send(t, "GET", p, "", bearer(token)...), 429, "rate_limited")
	}
}
