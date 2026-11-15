//go:build integration

package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/learning"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/lifecycle"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/maintenance"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
)

// rightsJobs runs the TRD 04 jobs with a chosen batch size and export timeout until no
// operation is pending or the pass budget runs out; it returns the passes used.
func (e *signupEnv) rightsJobs(t *testing.T, batch int32, exportTimeout time.Duration, passes int, each func()) int {
	t.Helper()
	keys, err := notify.NewKeyring(notify.Key{ID: 1, Key: outboxKey1})
	if err != nil {
		t.Fatal(err)
	}
	jobs := lifecycle.New(e.d.Pool, nil, keys, e.hmac, e.metrics, nil)
	if exportTimeout > 0 {
		jobs.SetExportTimeout(exportTimeout)
	}
	r, err := maintenance.New(maintenance.Config{Pool: e.d.Pool, AccountJob: jobs.RunBatch, BatchSize: batch})
	if err != nil {
		t.Fatal(err)
	}
	for i := 1; i <= passes; i++ {
		if res := resultOf(t, r.RunOnce(context.Background()), "account_lifecycle"); res.Err != nil {
			t.Fatalf("pass %d: %v", i, res.Err)
		}
		if each != nil {
			each()
		}
		if rowCount(t, e.d.Pool, `SELECT count(*) FROM account_operations WHERE state = 'pending'`) == 0 {
			return i
		}
	}
	t.Fatal("rights jobs did not finish")
	return 0
}

// rawGet calls the real router without the contract wrapper, for bulk or deliberately aborted bodies.
func (e *signupEnv) rawGet(t *testing.T, path string, headers ...string) (status int, contentLength int64, body []byte, readErr error) {
	t.Helper()
	srv := httptest.NewServer(e.handler)
	defer srv.Close()
	req, _ := http.NewRequest(http.MethodGet, srv.URL+path, nil)
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Add(headers[i], headers[i+1])
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, -1, nil, err // aborted before the headers reached the client
	}
	defer res.Body.Close()
	body, readErr = io.ReadAll(res.Body)
	return res.StatusCode, res.ContentLength, body, readErr
}

func (e *signupEnv) exportReady(t *testing.T, email string, timeout time.Duration) rightsProof {
	t.Helper()
	p, r := e.rightsStart(t, "export", email)
	wantStatus(t, r, http.StatusAccepted)
	wantStatus(t, e.rightsComplete(t, p), http.StatusAccepted)
	e.rightsJobs(t, 1000, timeout, 5, nil)
	if e.rightsStatus(t, p).str("state") != "ready" {
		t.Fatal("export not ready")
	}
	return p
}

func TestLearningRights_ExportIncludesVocabularyAndFailsClosed(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	u := newUser(t, e.q)
	d := e.device(t, u, "D")
	keep, drop := uuid.New(), uuid.New()
	d.mustPush(t, mCreate(d.next(), keep, with(wordData(`say "hi"`), map[string]any{"tags": []string{"t"}})), mCreate(d.next(), drop, wordData("gone")))
	d.mustPush(t, mDelete(d.next(), drop, int64(e.headRevision(t, u.ID))))
	p := e.exportReady(t, u.Email, 0)
	file := e.download(t, p) // through the contract checker: AccountExport schema version 2
	wantStatus(t, file, http.StatusOK)
	if cl, _ := strconv.Atoi(file.header.Get("Content-Length")); cl != len(file.raw) {
		t.Fatalf("Content-Length %d, body %d", cl, len(file.raw))
	}
	var doc struct {
		SchemaVersion int               `json:"schema_version"`
		Vocabulary    []json.RawMessage `json:"vocabulary"`
	}
	if err := json.Unmarshal(file.raw, &doc); err != nil || doc.SchemaVersion != 3 || len(doc.Vocabulary) != 1 {
		t.Fatalf("export: %v %+v", err, doc)
	}
	content := string(learning.AppendCanonical(nil, learning.Content{Word: `say "hi"`, Meaning: "m", Examples: []string{}, Tags: []string{"t"}}))
	if !strings.Contains(string(doc.Vocabulary[0]), `"content":`+content+`}`) || !strings.Contains(string(doc.Vocabulary[0]), keep.String()) {
		t.Fatalf("the export writes the canonical content: %s", doc.Vocabulary[0])
	}
	if strings.Contains(string(file.raw), drop.String()) {
		t.Fatal("tombstones are not exported")
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM account_operations WHERE id = $1 AND schema_version = 3 AND artifact_plain_bytes = $2`, uuid.MustParse(p.id), len(file.raw)) != 1 {
		t.Fatal("artifact_plain_bytes")
	}
	op := uuid.MustParse(p.id)
	// Tampering fails closed: a flipped final flag, a substituted byte, a missing final chunk.
	for name, sql := range map[string]string{
		"final flag": `UPDATE account_export_chunks SET final = NOT final WHERE operation_id = $1 AND seq = 0`,
		"byte":       `UPDATE account_export_chunks SET sealed = overlay(sealed placing '\xff'::bytea from 20 for 1) WHERE operation_id = $1 AND seq = 0`,
	} {
		t.Run(name, func(t *testing.T) {
			var saved []byte
			if err := e.d.Pool.QueryRow(context.Background(), `SELECT sealed FROM account_export_chunks WHERE operation_id = $1 AND seq = 0`, op).Scan(&saved); err != nil {
				t.Fatal(err)
			}
			mustExec(t, e.d.Pool, sql, op)
			_, cl, body, rerr := e.rawGet(t, p.statusPath()+"/download", rightsHeaders(p.cap)...)
			if rerr == nil && int64(len(body)) == cl {
				t.Fatal("a tampered export must abort short of Content-Length")
			}
			mustExec(t, e.d.Pool, `UPDATE account_export_chunks SET sealed = $2, final = true WHERE operation_id = $1 AND seq = 0`, op, saved)
		})
	}
	// Cancellation (deactivation here) deletes the chunks in the same transaction.
	s := e.issue(t, u, "owner")
	want204(t, e.deactivate(t, s.AccessToken, 0))
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM account_export_chunks WHERE operation_id = $1`, op) != 0 {
		t.Fatal("canceled export kept its chunks")
	}
	// The 24 h expiry deletes them too (a deactivated owner may still export).
	mustExec(t, e.d.Pool, `UPDATE account_operations SET accepted_at = now() - interval '25 hours' WHERE id = $1`, op)
	mustExec(t, e.d.Pool, `UPDATE otp_cooldowns SET last_issued_at = now() - interval '2 minutes'`)
	p2 := e.exportReady(t, u.Email, 0)
	op2 := uuid.MustParse(p2.id)
	mustExec(t, e.d.Pool, `UPDATE account_operations SET download_expires_at = now() WHERE id = $1`, op2)
	e.finishRightsJobs(t)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM account_export_chunks WHERE operation_id = $1`, op2) != 0 {
		t.Fatal("expired export kept its chunks")
	}
}

func TestLearningRights_MultiChunkExportDetectsReorderAndTruncation(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	u := newUser(t, e.q)
	d := e.device(t, u, "D")
	rnd := rand.New(rand.NewPCG(1, 2))
	for range 6 { // 600 words of about 4 KiB: more than two 1 MiB chunks
		muts := make([]map[string]any, 100)
		for i := range muts {
			muts[i] = mCreate(d.next(), uuid.New(), with(wordData("w"), map[string]any{"meaning": randomText(rnd, 1500), "examples": []string{randomText(rnd, 500), randomText(rnd, 500), randomText(rnd, 500), randomText(rnd, 500), randomText(rnd, 500)}}))
		}
		for _, r := range d.mustPush(t, muts...).Results {
			wantOutcome(t, r, "applied", "")
		}
	}
	p := e.exportReady(t, u.Email, 0)
	op := uuid.MustParse(p.id)
	if n := rowCount(t, e.d.Pool, `SELECT count(*) FROM account_export_chunks WHERE operation_id = $1`, op); n < 3 {
		t.Fatalf("want at least 3 chunks, got %d", n)
	}
	status, cl, body, rerr := e.rawGet(t, p.statusPath()+"/download", rightsHeaders(p.cap)...)
	if status != 200 || rerr != nil || int64(len(body)) != cl || !json.Valid(body) {
		t.Fatalf("multi-chunk download: %d %v %d/%d", status, rerr, len(body), cl)
	}
	swap01(t, e, op)
	if _, cl, body, rerr := e.rawGet(t, p.statusPath()+"/download", rightsHeaders(p.cap)...); rerr == nil && int64(len(body)) == cl {
		t.Fatal("reordered chunks must abort")
	}
	swap01(t, e, op)
	mustExec(t, e.d.Pool, `DELETE FROM account_export_chunks WHERE operation_id = $1 AND final`, op)
	if _, cl, body, rerr := e.rawGet(t, p.statusPath()+"/download", rightsHeaders(p.cap)...); rerr == nil && int64(len(body)) == cl {
		t.Fatal("a missing final chunk must abort")
	}
}

// swap01 exchanges chunks 0 and 1 through a free sequence number (the primary key is immediate).
func swap01(t *testing.T, e *signupEnv, op uuid.UUID) {
	t.Helper()
	for _, step := range [][2]int{{0, 75}, {1, 0}, {75, 1}} {
		mustExec(t, e.d.Pool, `UPDATE account_export_chunks SET seq = $3 WHERE operation_id = $1 AND seq = $2`, op, step[0], step[1])
	}
}

func randomText(r *rand.Rand, n int) string {
	const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, n)
	for i := range b {
		b[i] = alphabet[r.IntN(len(alphabet))]
	}
	return string(b)
}

// A stale device racing deletion acceptance, both orders; the purge drains learning rows in
// bounded batches and resumes after a failure; re-registration with the same email starts empty.
func TestLearningRights_DeletionRacesPurgeAndReregistration(t *testing.T) {
	for _, first := range []string{"push", "acceptance"} {
		t.Run(first, func(t *testing.T) {
			e := newSignupEnv(t, nil)
			e.openSync(t)
			u := newUser(t, e.q)
			stale := e.device(t, u, "stale")
			oldID := uuid.New()
			stale.mustPush(t, mCreate(stale.next(), oldID, wordData("old")))
			_, oldSnap := stale.snapshot(t, "", 10)
			p, r := e.rightsStart(t, "delete", u.Email)
			wantStatus(t, r, http.StatusAccepted)
			raced := uuid.New()
			pushed, accepted := make(chan response, 1), make(chan response, 1)
			push := func() {
				r, _ := stale.push(t, mCreate(stale.next(), raced, wordData("raced")))
				pushed <- r
			}
			if first == "push" {
				tx, err := e.d.Pool.Begin(context.Background())
				if err != nil {
					t.Fatal(err)
				}
				if _, err := tx.Exec(context.Background(), `SELECT 1 FROM learning_sync_heads WHERE user_id = $1 FOR UPDATE`, u.ID); err != nil {
					t.Fatal(err)
				}
				go push() // holds L3 KEY SHARE and the session, waits at the head
				waitForLockWaiters(t, e, 1)
				go func() { accepted <- e.rightsComplete(t, p) }() // waits to revoke the pushing session
				waitForLockWaiters(t, e, 2)
				if err := tx.Commit(context.Background()); err != nil {
					t.Fatal(err)
				}
				wantStatus(t, <-pushed, http.StatusOK)
				wantStatus(t, <-accepted, http.StatusAccepted)
			} else {
				release := managementGate(t, e, "account.delete.request") // sessions already revoked, uncommitted
				go func() { accepted <- e.rightsComplete(t, p) }()
				waitForLockWaiters(t, e, 1)
				go push() // waits on the acting session, then finds it revoked
				waitForLockWaiters(t, e, 2)
				release()
				wantStatus(t, <-accepted, http.StatusAccepted)
				wantUnauthorized(t, <-pushed)
				if rowCount(t, e.d.Pool, `SELECT count(*) FROM vocabulary_items WHERE id = $1`, raced) != 0 {
					t.Fatal("a push after acceptance must write nothing")
				}
			}
			// The stale device is cut off everywhere.
			wantUnauthorized(t, e.get(t, pathLState, bearer(stale.access)...))
			wantUnauthorized(t, e.get(t, pathLChanges+"?cursor="+oldSnap.CatchUpCursor, bearer(stale.access)...))
			wantUnauthorized(t, e.refresh(t, stale.refr))
			// Purge: 2,500 more words drain in bounded batches; a failure stalls it, sealed.
			mustExec(t, e.d.Pool, `INSERT INTO vocabulary_items (user_id, id, word, meaning, examples, tags, capture_day, client_created_at,
				content_bytes, revision, created_revision, field_revisions)
				SELECT $1, gen_random_uuid(), 'w', 'm', '{}', '{}', '2026-11-14', now(), 100, 1000 + g, 1000 + g, '{}' FROM generate_series(1, 2500) g`, u.ID)
			mustExec(t, e.d.Pool, `CREATE FUNCTION fail_mutation_purge() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic purge failure'; END $$`)
			mustExec(t, e.d.Pool, `CREATE TRIGGER fail_mutation_purge BEFORE DELETE ON learning_mutations FOR EACH ROW EXECUTE FUNCTION fail_mutation_purge()`)
			keys, _ := notify.NewKeyring(notify.Key{ID: 1, Key: outboxKey1})
			jobs := lifecycle.New(e.d.Pool, nil, keys, e.hmac, e.metrics, nil)
			runner, _ := maintenance.New(maintenance.Config{Pool: e.d.Pool, AccountJob: jobs.RunBatch, BatchSize: 1000})
			failed, prev := false, rowCount(t, e.d.Pool, `SELECT count(*) FROM vocabulary_items WHERE user_id = $1`, u.ID)
			for range 30 {
				if resultOf(t, runner.RunOnce(context.Background()), "account_lifecycle").Err != nil {
					failed = true
					break
				}
				now := rowCount(t, e.d.Pool, `SELECT count(*) FROM vocabulary_items WHERE user_id = $1`, u.ID)
				if prev-now > 1000 {
					t.Fatalf("one checkpoint removed %d words, over the batch", prev-now)
				}
				prev = now
			}
			if !failed || rowCount(t, e.d.Pool, `SELECT count(*) FROM vocabulary_items WHERE user_id = $1`, u.ID) != 0 ||
				rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_mutations WHERE user_id = $1`, u.ID) == 0 ||
				rowCount(t, e.d.Pool, `SELECT count(*) FROM users WHERE id = $1 AND status = 'pending_deletion'`, u.ID) != 1 ||
				e.rightsStatus(t, p).str("state") != "pending" {
				t.Fatal("an interrupted purge must stall sealed, words first, records after")
			}
			mustExec(t, e.d.Pool, `DROP TRIGGER fail_mutation_purge ON learning_mutations`)
			e.rightsJobs(t, 1000, 0, 40, nil)
			if e.rightsStatus(t, p).str("state") != "completed" ||
				rowCount(t, e.d.Pool, `SELECT (SELECT count(*) FROM vocabulary_items WHERE user_id = $1) + (SELECT count(*) FROM learning_sync_writers WHERE user_id = $1)
					+ (SELECT count(*) FROM learning_mutations WHERE user_id = $1) + (SELECT count(*) FROM learning_sync_heads WHERE user_id = $1) + (SELECT count(*) FROM users WHERE id = $1)`, u.ID) != 0 {
				t.Fatal("purge must remove every learning row and the account")
			}
			// Re-registration with the same email: a new user_id, head and epoch; nothing old.
			mustExec(t, e.d.Pool, `UPDATE otp_cooldowns SET last_issued_at = now() - interval '2 minutes' WHERE purpose = 'signup'`)
			code := e.queueCode()
			ack := e.startOTP(t, u.Email)
			wantStatus(t, ack, http.StatusAccepted)
			created := e.verify(t, ack.str("challenge_token"), code)
			wantStatus(t, created, http.StatusCreated)
			u2 := uuid.MustParse(userID(created))
			if u2 == u.ID {
				t.Fatal("re-registration must get a new user_id")
			}
			newAccess := created.str("access_token")
			rc := e.get(t, pathLChanges+"?cursor="+oldSnap.CatchUpCursor, bearer(newAccess)...)
			wantProblem(t, rc, http.StatusGone, "sync_reset_required")
			if rc.str("reason") != "epoch_changed" {
				t.Fatalf("old cursor under the new account: %s", rc.raw)
			}
			old := stale.body(mCreate(stale.seq+1, uuid.New(), wordData("w")))
			old["epoch"] = uuid.MustParse(rc.str("epoch"))
			if r := e.post(t, pathLPush, old, bearer(newAccess)...); r.str("reason") != "writer_unknown" {
				t.Fatalf("old writer under the new account: %s", r.raw)
			}
			nd := &device{e: e, access: newAccess}
			nd.register(t)
			// Word ids are owner-scoped: the new account may use the old id; it gets no old data.
			wantOutcome(t, nd.mustPush(t, mCreate(nd.next(), oldID, wordData("new"))).Results[0], "applied", "")
			view, _ := nd.fullSync(t)
			if len(view) != 1 || view[oldID].field("word") != "new" {
				t.Fatalf("the new account sees only its own words: %+v", view)
			}
		})
	}
}

// D7 at the limit: 50,000 live words whose canonical content totals exactly 64 MiB, with
// 19-digit revisions and year-9999 timestamps (the widest envelope). The export stays within the
// verified plaintext, chunk and sealed-payload bounds while a push runs, and the purge drains it
// in bounded checkpoints.
func TestLearningRights_ExportAndPurgeAtTheLimit(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	u := newUser(t, e.q)
	d := e.device(t, u, "D")
	const base = int64(9_000_000_000_000_000_000)
	max := time.Date(9999, 12, 31, 23, 59, 59, 999_000_000, time.UTC)
	rnd := rand.New(rand.NewPCG(3, 4))
	rows := make([][]any, 0, learning.MaxLiveWords)
	var total int64
	ids := make([]uuid.UUID, learning.MaxLiveWords)
	for i := range learning.MaxLiveWords {
		target := learning.MaxContentBytes / learning.MaxLiveWords // 1,342
		if i < learning.MaxContentBytes%learning.MaxLiveWords {
			target++ // 8,864 words of 1,343 bytes make the total exact
		}
		c := learning.Content{Word: "w" + strconv.Itoa(i), Examples: []string{}, Tags: []string{}}
		pad := target - learning.CanonicalSize(c)
		c.Meaning = strings.Repeat(`"`, 50) + randomText(rnd, pad-100) // 50 escaped quotes: 100 bytes
		if learning.CanonicalSize(c) != target {
			t.Fatalf("fixture size %d != %d", learning.CanonicalSize(c), target)
		}
		total += int64(target)
		ids[i] = uuid.New()
		rows = append(rows, []any{u.ID, ids[i], c.Word, c.Meaning, c.Examples, c.Tags, max, max, int32(target),
			base + int64(i) + 1, base + int64(i) + 1, []byte(`{}`), max, max})
	}
	if total != learning.MaxContentBytes {
		t.Fatalf("fixture total %d", total)
	}
	if _, err := e.d.Pool.CopyFrom(context.Background(), pgx.Identifier{"vocabulary_items"},
		[]string{"user_id", "id", "word", "meaning", "examples", "tags", "capture_day", "client_created_at", "content_bytes",
			"revision", "created_revision", "field_revisions", "created_at", "updated_at"}, pgx.CopyFromRows(rows)); err != nil {
		t.Fatal(err)
	}
	rows = nil
	mustExec(t, e.d.Pool, `UPDATE learning_sync_heads SET revision = $2, live_words = $3, content_bytes = $4 WHERE user_id = $1`,
		u.ID, base+int64(learning.MaxLiveWords), learning.MaxLiveWords, learning.MaxContentBytes)

	p, r := e.rightsStart(t, "export", u.Email)
	wantStatus(t, r, http.StatusAccepted)
	wantStatus(t, e.rightsComplete(t, p), http.StatusAccepted)
	pushed := make(chan lpushOut, 1)
	e.rightsJobs(t, 1000, 15*time.Minute, 5, nil)
	go func() { // a same-size edit concurrent with the download and the purge setup below
		pushed <- d.mustPush(t, mUpdate(d.next(), ids[7], base+int64(learning.MaxLiveWords), map[string]any{"word": "w8"}))
	}()
	op := uuid.MustParse(p.id)
	var plain int64
	var chunks, maxChunk, sealed int64
	if err := e.d.Pool.QueryRow(context.Background(), `SELECT o.artifact_plain_bytes, count(c.*), max(octet_length(c.sealed)), sum(octet_length(c.sealed))
		FROM account_operations o JOIN account_export_chunks c ON c.operation_id = o.id WHERE o.id = $1 GROUP BY o.artifact_plain_bytes`, op).
		Scan(&plain, &chunks, &maxChunk, &sealed); err != nil {
		t.Fatal(err)
	}
	floor := int64(learning.MaxContentBytes) + int64(learning.MaxLiveWords)*(learning.EnvelopeBytes-1)
	if plain < floor || plain > learning.MaxExportPlainBytes || chunks > learning.MaxExportChunks || maxChunk > learning.MaxSealedChunkBytes || sealed > learning.MaxSealedExportBytes {
		t.Fatalf("export bound: plain %d (floor %d, bound %d), chunks %d, max sealed chunk %d, sealed total %d (bound %d)",
			plain, floor, learning.MaxExportPlainBytes, chunks, maxChunk, sealed, learning.MaxSealedExportBytes)
	}
	t.Logf("at the limit: plaintext %d bytes, %d chunks, largest sealed chunk %d, sealed payload %d", plain, chunks, maxChunk, sealed)
	status, cl, body, rerr := e.rawGet(t, p.statusPath()+"/download", rightsHeaders(p.cap)...)
	if status != 200 || rerr != nil || cl != plain || int64(len(body)) != plain {
		t.Fatalf("download: %d %v %d/%d/%d", status, rerr, len(body), cl, plain)
	}
	var doc struct {
		Vocabulary []json.RawMessage `json:"vocabulary"`
	}
	if err := json.NewDecoder(bytes.NewReader(body)).Decode(&doc); err != nil || len(doc.Vocabulary) != learning.MaxLiveWords {
		t.Fatalf("download decodes to %d words: %v", len(doc.Vocabulary), err)
	}
	body, doc.Vocabulary = nil, nil
	wantOutcome(t, (<-pushed).Results[0], "applied", "")

	// Purge at the limit: bounded checkpoints, nothing left, no cascade.
	dp, r := e.rightsStart(t, "delete", u.Email)
	wantStatus(t, r, http.StatusAccepted)
	wantStatus(t, e.rightsComplete(t, dp), http.StatusAccepted)
	prev := learning.MaxLiveWords
	passes := e.rightsJobs(t, 10_000, 0, 40, func() {
		now := rowCount(t, e.d.Pool, `SELECT count(*) FROM vocabulary_items WHERE user_id = $1`, u.ID)
		if prev-now > 10_000 {
			t.Fatalf("a checkpoint removed %d words, over the batch", prev-now)
		}
		prev = now
	})
	if e.rightsStatus(t, dp).str("state") != "completed" || rowCount(t, e.d.Pool, `SELECT count(*) FROM users WHERE id = $1`, u.ID) != 0 {
		t.Fatal("purge at the limit did not complete")
	}
	t.Logf("purge of 50,000 words: %d runner passes at batch 10,000", passes)
}
