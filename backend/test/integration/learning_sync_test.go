//go:build integration

package integration

import (
	"context"
	"errors"
	"net/http"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/learning"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/maintenance"
)

func (e *signupEnv) learningCleanup(t *testing.T, batch int32, maxBatches int) maintenance.Result {
	t.Helper()
	r, err := maintenance.New(maintenance.Config{Pool: e.d.Pool, LearningJob: learning.Cleanup, BatchSize: batch, MaxBatches: maxBatches})
	if err != nil {
		t.Fatal(err)
	}
	return resultOf(t, r.RunOnce(context.Background()), "learning_sync")
}

func TestLearningSync_TwoOfflineDevices(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	u := newUser(t, e.q)
	a, b := e.device(t, u, "A"), e.device(t, u, "B")
	x := uuid.New()
	out := a.mustPush(t, mCreate(a.next(), x, wordData("serendipity")))
	wantOutcome(t, out.Results[0], "applied", "")
	r1 := *out.Results[0].Revision

	// Both offline from r1. Different fields merge, whichever order they arrive in.
	ra := a.mustPush(t, mUpdate(a.next(), x, r1, map[string]any{"meaning": "happy accident"}))
	rb := b.mustPush(t, mUpdate(b.next(), x, r1, map[string]any{"tags": []string{"b1"}}))
	wantOutcome(t, ra.Results[0], "applied", "")
	wantOutcome(t, rb.Results[0], "applied", "")
	if rb.Results[0].Record.field("meaning") != "happy accident" || len(rb.Results[0].ConflictedFields) != 0 {
		t.Fatalf("different fields must merge: %+v", rb.Results[0])
	}
	base := *rb.Results[0].Revision
	// The same field: the later-accepted edit wins and says what it overwrote.
	a.mustPush(t, mUpdate(a.next(), x, base, map[string]any{"meaning": "from A"}))
	rb = b.mustPush(t, mUpdate(b.next(), x, base, map[string]any{"meaning": "from B"}))
	wantOutcome(t, rb.Results[0], "merged", "")
	if rb.Results[0].Record.field("meaning") != "from B" || !reflect.DeepEqual(rb.Results[0].ConflictedFields, []string{"meaning"}) {
		t.Fatalf("last server-accepted edit: %+v", rb.Results[0])
	}
	cur := rb.Results[0].Record.Revision
	// Edit after a remote delete, delete after a remote edit, explicit restore, stale restore.
	del := a.mustPush(t, mDelete(a.next(), x, cur))
	wantOutcome(t, del.Results[0], "applied", "")
	wantOutcome(t, b.mustPush(t, mUpdate(b.next(), x, cur, map[string]any{"word": "late"})).Results[0], "rejected", "deleted_on_server")
	wantOutcome(t, b.mustPush(t, mRestore(b.next(), x, cur, wordData("serendipity"))).Results[0], "rejected", "stale_base")
	back := b.mustPush(t, mRestore(b.next(), x, *del.Results[0].Revision, wordData("serendipity again")))
	wantOutcome(t, back.Results[0], "applied", "")
	if back.Results[0].Record.Deleted || back.Results[0].Record.field("word") != "serendipity again" {
		t.Fatalf("restore carries full content: %+v", back.Results[0].Record)
	}
	y := uuid.New()
	a.mustPush(t, mUpdate(a.next(), y, 0, map[string]any{"word": "w"})) // unknown_item, still processed
	ry := b.mustPush(t, mUpdate(b.next(), x, *back.Results[0].Revision, map[string]any{"tags": []string{}}), mDelete(b.next(), x, 0))
	wantOutcome(t, ry.Results[1], "applied", "") // a delete beats edits that arrived after its base
	// The same word created offline on both: two items, no server-side deduplication.
	future := wordData("again")
	future["client_created_at"] = "9999-12-31T23:59:59.999Z" // a skewed clock decides nothing
	a.mustPush(t, mCreate(a.next(), uuid.New(), wordData("again")))
	b.mustPush(t, mCreate(b.next(), uuid.New(), future))
	va, _ := a.fullSync(t)
	vb, _ := b.fullSync(t)
	if !reflect.DeepEqual(va, vb) || len(va) != 2 {
		t.Fatalf("devices must converge on two words: %d %d", len(va), len(vb))
	}
}

// The §5.4 sequence: a lost response, a retry inside the window, expiry, a retry with a fresh
// cursor (unchanged, and rewritten by a faulty client), the high-water read and a new edit.
func TestLearningSync_LostResponseAndExpiry(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	u := newUser(t, e.q)
	d, other := e.device(t, u, "D"), e.device(t, u, "E")
	x := uuid.New()
	r100 := *d.mustPush(t, mCreate(d.next(), x, wordData("x"))).Results[0].Revision
	original := mUpdate(d.next(), x, r100, map[string]any{"meaning": "b"})
	first := d.mustPush(t, original) // "the response is lost": the test ignores it
	r101 := *first.Results[0].Revision
	r102 := *other.mustPush(t, mUpdate(other.next(), x, r101, map[string]any{"meaning": "c"})).Results[0].Revision
	head := e.headRevision(t, u.ID)

	// A refusal of a later attempt says nothing about the first one.
	mustExec(t, e.d.Pool, `UPDATE rate_limit_counters SET count = 10000 WHERE key LIKE 'learning_push:%'`)
	limited, _ := d.push(t, original)
	wantProblem(t, limited, http.StatusTooManyRequests, "rate_limited")
	mustExec(t, e.d.Pool, `DELETE FROM rate_limit_counters WHERE key LIKE 'learning_push:%'`)

	dup := d.mustPush(t, original)
	r := dup.Results[0]
	if r.Outcome != "duplicate" || r.OriginalOutcome != "applied" || *r.Revision != r101 || r.Record.field("meaning") != "c" || r.Record.Revision != r102 {
		t.Fatalf("retry inside the window: %+v", r)
	}
	if e.headRevision(t, u.ID) != head {
		t.Fatal("a duplicate must not allocate a revision")
	}
	reused := mUpdate(original["seq"].(int64), x, r100, map[string]any{"meaning": "other"})
	wantOutcome(t, d.mustPush(t, reused).Results[0], "rejected", "mutation_reused")

	mustExec(t, e.d.Pool, `UPDATE learning_mutations SET created_at = now() - interval '31 days' WHERE writer_id = $1`, d.writer)
	if res := e.learningCleanup(t, 1000, 10); res.Err != nil || res.Rows == 0 {
		t.Fatalf("record expiry: %+v", res)
	}
	if d.state(t).Writer.LastSeq != 2 {
		t.Fatal("last_seq outlives its records")
	}
	_, fresh := d.changes(t, d.mustSnapshotCursor(t)) // a fresh cursor changes nothing
	_ = fresh
	wantOutcome(t, d.mustPush(t, original).Results[0], "rejected", "mutation_expired")
	rebased := mUpdate(original["seq"].(int64), x, r102, map[string]any{"meaning": "b"}) // a faulty client
	wantOutcome(t, d.mustPush(t, rebased).Results[0], "rejected", "mutation_expired")
	if e.headRevision(t, u.ID) != head || rowCount(t, e.d.Pool, `SELECT count(*) FROM vocabulary_items WHERE meaning = 'c' AND id = $1`, x) != 1 {
		t.Fatal("an expired mutation must never apply")
	}
	// Only an explicit new edit (a new seq) applies.
	wantOutcome(t, d.mustPush(t, mUpdate(d.next(), x, r102, map[string]any{"meaning": "b"})).Results[0], "applied", "")
	gap, _ := d.push(t, mDelete(d.seq+2, x, 0))
	wantProblem(t, gap, http.StatusConflict, "sequence_gap")
	if d.state(t).Writer.LastSeq != d.seq {
		t.Fatal("a refused request leaves last_seq")
	}
}

func (d *device) mustSnapshotCursor(t *testing.T) string {
	t.Helper()
	_, s := d.snapshot(t, "", 500)
	return s.CatchUpCursor
}

func TestLearningSync_ConcurrentIdenticalAndConcurrentEdits(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	u := newUser(t, e.q)
	a, b := e.device(t, u, "A"), e.device(t, u, "B")
	x := uuid.New()
	r1 := *a.mustPush(t, mCreate(a.next(), x, wordData("x"))).Results[0].Revision
	m := mUpdate(a.next(), x, r1, map[string]any{"meaning": "same"})
	var wg sync.WaitGroup
	outs := make([]lpushOut, 2)
	for i := range 2 {
		wg.Add(1)
		go func() { defer wg.Done(); outs[i] = a.mustPush(t, m) }()
	}
	wg.Wait()
	got := []string{outs[0].Results[0].Outcome, outs[1].Results[0].Outcome}
	if !(got[0] == "applied" && got[1] == "duplicate") && !(got[0] == "duplicate" && got[1] == "applied") {
		t.Fatalf("concurrent identical requests: %v", got)
	}
	// Two sessions of one owner, both orders forced at the head lock: gap-free revisions.
	for _, first := range []*device{a, b} {
		tx, err := e.d.Pool.Begin(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(context.Background(), `SELECT 1 FROM learning_sync_heads WHERE user_id = $1 FOR UPDATE`, u.ID); err != nil {
			t.Fatal(err)
		}
		second := map[*device]*device{a: b, b: a}[first]
		base := int64(e.headRevision(t, u.ID))
		res := make(chan lpushOut, 2)
		go func() { res <- first.mustPush(t, mUpdate(first.next(), x, base, map[string]any{"meaning": "1"})) }()
		waitForLockWaiters(t, e, 1)
		go func() { res <- second.mustPush(t, mUpdate(second.next(), x, base, map[string]any{"meaning": "2"})) }()
		waitForLockWaiters(t, e, 2)
		// A pull while both wait never skips a revision later.
		if err := tx.Commit(context.Background()); err != nil {
			t.Fatal(err)
		}
		o1, o2 := <-res, <-res
		revs := []int64{*o1.Results[0].Revision, *o2.Results[0].Revision}
		if revs[0]+revs[1] != 2*base+3 || revs[0] == revs[1] {
			t.Fatalf("revisions must be base+1 and base+2: %v from %d", revs, base)
		}
	}
	// Two owners never block each other.
	tx, err := e.d.Pool.Begin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	if _, err := tx.Exec(context.Background(), `SELECT 1 FROM learning_sync_heads WHERE user_id = $1 FOR UPDATE`, u.ID); err != nil {
		t.Fatal(err)
	}
	c := e.device(t, newUser(t, e.q), "C")
	c.mustPush(t, mCreate(c.next(), uuid.New(), wordData("free")))
}

// Point 2: processed seq values are resolved before import capacity admission, and admission
// applies only to the new suffix.
func TestLearningSync_ImportCapacityAfterProcessedPrefix(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	u := newUser(t, e.q)
	d, other := e.device(t, u, "D"), e.device(t, u, "E")
	g1, g2, g3 := uuid.New(), uuid.New(), uuid.New()
	m1, m2 := mCreate(d.next(), g1, wordData("g1")), mCreate(d.next(), g2, wordData("g2"))
	wantStatus(t, d.importWords(t, 0, 0, m1, m2), http.StatusOK)
	other.mustPush(t, mCreate(other.next(), uuid.New(), wordData("elsewhere"))) // capacity changes
	// An entirely processed retry still returns duplicates, whatever the stale basis says.
	retry := d.importWords(t, 0, 0, m1, m2)
	wantStatus(t, retry, http.StatusOK)
	for _, r := range decode[lpushOut](t, retry).Results {
		if r.Outcome != "duplicate" || r.OriginalOutcome != "applied" {
			t.Fatalf("processed retry: %+v", r)
		}
	}
	// A mixed batch: the processed prefix is resolved, the suffix is refused atomically.
	st := d.state(t)
	m3 := mCreate(d.next(), g3, wordData("g3"))
	refused := d.importWords(t, 2, st.ContentBytes, m1, m2, m3)
	wantProblem(t, refused, http.StatusConflict, "capacity_changed")
	if int64(refused.body["live_words"].(float64)) != 3 || int64(refused.body["last_seq"].(float64)) != 2 {
		t.Fatalf("capacity_changed body: %s", refused.raw)
	}
	if d.state(t).Writer.LastSeq != 2 || rowCount(t, e.d.Pool, `SELECT count(*) FROM vocabulary_items WHERE id = $1`, g3) != 0 {
		t.Fatal("a capacity refusal leaves the suffix and its seq values untouched")
	}
	ok := d.importWords(t, 3, st.ContentBytes, m1, m2, m3) // the user confirmed again
	wantStatus(t, ok, http.StatusOK)
	res := decode[lpushOut](t, ok).Results
	if res[0].Outcome != "duplicate" || res[1].Outcome != "duplicate" || res[2].Outcome != "applied" {
		t.Fatalf("resubmission: %+v", res)
	}
	// A matching basis whose creates do not fit is refused whole.
	mustExec(t, e.d.Pool, `UPDATE learning_sync_heads SET live_words = $2 WHERE user_id = $1`, u.ID, learning.MaxLiveWords-1)
	st = d.state(t)
	wantProblem(t, d.importWords(t, st.LiveWords, st.ContentBytes, mCreate(d.next(), uuid.New(), wordData("a")), mCreate(d.seq+1, uuid.New(), wordData("b"))),
		http.StatusConflict, "capacity_changed")
}

func TestLearningSync_QuotaAndValidationAtTheLimit(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	u := newUser(t, e.q)
	d := e.device(t, u, "D")
	x := uuid.New()
	d.mustPush(t, mCreate(d.next(), x, wordData("x")))
	mustExec(t, e.d.Pool, `UPDATE learning_sync_heads SET live_words = $2 WHERE user_id = $1`, u.ID, learning.MaxLiveWords-1)
	wantOutcome(t, d.mustPush(t, mCreate(d.next(), uuid.New(), wordData("50000th"))).Results[0], "applied", "")
	over := d.mustPush(t, mCreate(d.next(), uuid.New(), wordData("one too many"))).Results[0]
	wantOutcome(t, over, "rejected", "quota_exceeded")
	if over.Limit != "words" {
		t.Fatalf("limit: %+v", over)
	}
	both := d.mustPush(t, mDelete(d.next(), x, int64(e.headRevision(t, u.ID))), mCreate(d.next(), uuid.New(), wordData("fits again")))
	wantOutcome(t, both.Results[0], "applied", "")
	wantOutcome(t, both.Results[1], "applied", "")
	wantOutcome(t, d.mustPush(t, mRestore(d.next(), x, int64(e.headRevision(t, u.ID)), wordData("x"))).Results[0], "rejected", "quota_exceeded")
	// The byte budget, exactly and one byte over.
	mustExec(t, e.d.Pool, `UPDATE learning_sync_heads SET live_words = 10 WHERE user_id = $1`, u.ID)
	size := learning.CanonicalSize(learning.Content{Word: "fit", Meaning: "m", Examples: []string{}, Tags: []string{}})
	mustExec(t, e.d.Pool, `UPDATE learning_sync_heads SET content_bytes = $2 WHERE user_id = $1`, u.ID, learning.MaxContentBytes-size)
	wantOutcome(t, d.mustPush(t, mCreate(d.next(), uuid.New(), wordData("fit"))).Results[0], "applied", "")
	b := d.mustPush(t, mCreate(d.next(), uuid.New(), wordData("w"))).Results[0]
	if b.Code != "quota_exceeded" || b.Limit != "bytes" {
		t.Fatalf("byte budget: %+v", b)
	}
	mustExec(t, e.d.Pool, `UPDATE learning_sync_heads SET content_bytes = 0 WHERE user_id = $1`, u.ID)
	// Validation: code points, the separate 8 KiB size, characters, and the first failure.
	invalid := map[string]struct {
		data        map[string]any
		detail, fld string
	}{
		"word 201 code points": {with(wordData(strings.Repeat("🙂", 201)), nil), "field_too_long", "word"},
		"21 examples":          {with(wordData("w"), map[string]any{"examples": make([]string, 21)}), "too_many_entries", "examples"},
		"tag 51":               {with(wordData("w"), map[string]any{"tags": []string{strings.Repeat("t", 51)}}), "field_too_long", "tags"},
		"over 8 KiB within field limits": {with(wordData("w"), map[string]any{"meaning": strings.Repeat("ệ", 2000),
			"examples": []string{strings.Repeat("x", 500), strings.Repeat("x", 500), strings.Repeat("x", 500), strings.Repeat("x", 500), strings.Repeat("x", 500)}}), "item_too_large", ""},
		"CR":                  {with(wordData("a\rb"), nil), "control_character", ""},
		"part of speech":      {with(wordData("w"), map[string]any{"part_of_speech": "noun"}), "invalid_part_of_speech", ""},
		"date":                {with(wordData("w"), map[string]any{"capture_day": "2026-02-30"}), "invalid_date", ""},
		"control before date": {with(wordData("a\x01"), map[string]any{"capture_day": "nope"}), "control_character", ""},
	}
	for name, c := range invalid {
		r := d.mustPush(t, mCreate(d.next(), uuid.New(), c.data)).Results[0]
		if r.Code != "invalid_item" || r.Detail != c.detail || r.Field != c.fld {
			t.Errorf("%s: %+v", name, r)
		}
	}
	ok := d.mustPush(t, mCreate(d.next(), uuid.New(), with(wordData(strings.Repeat("🙂", 200)), map[string]any{"meaning": "tab\tand\nline"}))).Results[0]
	wantOutcome(t, ok, "applied", "")
	// Invalid UTF-8 inside a string value is a per-item invalid_utf8, not a silent U+FFFD.
	raw := `{"epoch":"` + d.epoch.String() + `","writer_id":"` + d.writer.String() + `","mutations":[{"seq":` + itoa(d.next()) +
		`,"op":"create","entity_id":"` + uuid.NewString() + `","data":{"word":"a` + "\xff" + `","meaning":"m","pronunciation":null,"part_of_speech":null,"source":null,"examples":[],"tags":[],"capture_day":"2026-11-14","client_created_at":"2026-11-14T00:00:00Z"}}]}`
	rr := e.post(t, pathLPush, raw, bearer(d.access)...)
	wantStatus(t, rr, http.StatusOK)
	if r := decode[lpushOut](t, rr).Results[0]; r.Detail != "invalid_utf8" {
		t.Fatalf("invalid UTF-8: %+v", r)
	}
	// Two devices racing for the last slot: exactly one wins.
	mustExec(t, e.d.Pool, `UPDATE learning_sync_heads SET live_words = $2 WHERE user_id = $1`, u.ID, learning.MaxLiveWords-1)
	d2 := e.device(t, u, "D2")
	var wg sync.WaitGroup
	outs := make([]lresult, 2)
	for i, dev := range []*device{d, d2} {
		wg.Add(1)
		m := mCreate(dev.next(), uuid.New(), wordData("race"))
		go func() { defer wg.Done(); outs[i] = dev.mustPush(t, m).Results[0] }()
	}
	wg.Wait()
	if (outs[0].Outcome == "applied") == (outs[1].Outcome == "applied") {
		t.Fatalf("last slot: %+v %+v", outs[0], outs[1])
	}
}

func with(base map[string]any, over map[string]any) map[string]any {
	for k, v := range over {
		base[k] = v
	}
	return base
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// Point 3: snapshot pages are bound to (account, epoch, H); writes during paging reach the client
// through catch-up from H, also when the tail is empty; compaction past H forces a restart.
func TestLearningSync_SnapshotCatchUpAndCompaction(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	u := newUser(t, e.q)
	d, w := e.device(t, u, "D"), e.device(t, u, "W")
	ids := make([]uuid.UUID, 7)
	for i := range ids {
		ids[i] = uuid.New()
		w.mustPush(t, mCreate(w.next(), ids[i], wordData("w"+itoa(int64(i)))))
	}
	// An unchanged account: the catch-up tail is empty but must still be read.
	view, _ := d.fullSync(t)
	if len(view) != 7 {
		t.Fatalf("snapshot: %d", len(view))
	}
	_, s := d.snapshot(t, "", 500)
	r, c := d.changes(t, s.CatchUpCursor)
	wantStatus(t, r, http.StatusOK)
	if len(c.Changes) != 0 || c.HasMore || c.Cursor != s.CatchUpCursor {
		t.Fatalf("empty tail: %+v", c)
	}
	// Writes between pages: none are lost across the hand-off.
	staged := map[uuid.UUID]lrecord{}
	_, p1 := d.snapshot(t, "", 3)
	for _, it := range p1.Items {
		staged[it.EntityID] = it
	}
	head := int64(e.headRevision(t, u.ID))
	w.mustPush(t, mUpdate(w.next(), p1.Items[0].EntityID, head, map[string]any{"meaning": "edited during paging"}))
	newID := uuid.New()
	w.mustPush(t, mCreate(w.next(), newID, wordData("created during paging")))
	token := *p1.NextPageToken
	_, p2 := d.snapshot(t, token, 3)
	victim := p2.Items[0].EntityID
	w.mustPush(t, mDelete(w.next(), victim, int64(e.headRevision(t, u.ID))))
	for _, it := range p2.Items {
		staged[it.EntityID] = it
	}
	for p := p2; p.NextPageToken != nil; {
		_, p = d.snapshot(t, *p.NextPageToken, 3)
		for _, it := range p.Items {
			staged[it.EntityID] = it
		}
	}
	if p1.SnapshotRevision != p2.SnapshotRevision {
		t.Fatal("every page reads as of the captured H")
	}
	final, _ := d.catchUp(t, staged, p1.CatchUpCursor)
	truth, _ := w.fullSync(t)
	if !reflect.DeepEqual(final, truth) || final[p1.Items[0].EntityID].field("meaning") != "edited during paging" {
		t.Fatalf("hand-off lost writes: %d vs %d", len(final), len(truth))
	}
	if _, ok := final[victim]; ok {
		t.Fatal("a delete during paging must reach the client")
	}
	if _, ok := final[newID]; !ok {
		t.Fatal("a create during paging must reach the client")
	}
	// Compaction overtakes the catch-up boundary: both the next page and the catch-up restart.
	_, q1 := d.snapshot(t, "", 2)
	gone := q1.Items[0].EntityID
	w.mustPush(t, mDelete(w.next(), gone, int64(e.headRevision(t, u.ID))))
	mustExec(t, e.d.Pool, `UPDATE vocabulary_items SET deleted_at = now() - interval '91 days' WHERE id = $1`, gone)
	if res := e.learningCleanup(t, 1000, 10); res.Err != nil {
		t.Fatal(res.Err)
	}
	rp, _ := d.snapshot(t, *q1.NextPageToken, 2)
	wantProblem(t, rp, http.StatusGone, "sync_reset_required")
	rc, _ := d.changes(t, q1.CatchUpCursor)
	if rc.str("reason") != "cursor_compacted" || rp.str("reason") != "cursor_compacted" {
		t.Fatalf("compaction past H: %s %s", rp.raw, rc.raw)
	}
	// A stale edit to the compacted word is refused, never resurrected.
	wantOutcome(t, d.mustPush(t, mUpdate(d.next(), gone, 1, map[string]any{"word": "back"})).Results[0], "rejected", "stale_base")
	wantOutcome(t, d.mustPush(t, mDelete(d.next(), uuid.New(), int64(e.headRevision(t, u.ID)))).Results[0], "rejected", "unknown_item")
	if again, _ := d.fullSync(t); len(again) != len(truth)-1 {
		t.Fatalf("restart after compaction: %d", len(again))
	}
}

// Point 6 and D9: logical retirement, deterministic ties, immediate refusal, bounded removal.
func TestLearningSync_WritersRetirementAndCleanup(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	u := newUser(t, e.q)
	keep := e.device(t, u, "keep")
	reg := func() { // registration is limited to 10 a minute per session; the fixture needs more
		mustExec(t, e.d.Pool, `DELETE FROM rate_limit_counters WHERE key LIKE 'learning_writer:%'`)
		keep.register(t)
	}
	for i := 1; i < learning.MaxActiveWriters; i++ {
		reg() // the device re-registers; earlier writers stay active
	}
	if n := rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_sync_writers WHERE user_id = $1 AND retired_at IS NULL`, u.ID); n != 20 {
		t.Fatalf("active writers: %d", n)
	}
	var w [3]uuid.UUID
	rows, err := e.d.Pool.Query(context.Background(), `SELECT writer_id FROM learning_sync_writers WHERE user_id = $1 ORDER BY writer_id LIMIT 3`, u.ID)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; rows.Next(); i++ {
		if err := rows.Scan(&w[i]); err != nil {
			t.Fatal(err)
		}
	}
	rows.Close()
	// Pin the order: w0 and w1 tie on last_used_at and created_at (w0 has the lower id); w2
	// ties on last_used_at but is older. Expected order: w2, then w0, then w1.
	mustExec(t, e.d.Pool, `UPDATE learning_sync_writers SET last_used_at = '2000-01-01', created_at = '2000-01-01' WHERE writer_id = ANY($1)`, []uuid.UUID{w[0], w[1]})
	mustExec(t, e.d.Pool, `UPDATE learning_sync_writers SET last_used_at = '2000-01-01', created_at = '1999-01-01' WHERE writer_id = $1`, w[2])
	retired := func() []uuid.UUID {
		var out []uuid.UUID
		rows, err := e.d.Pool.Query(context.Background(), `SELECT writer_id FROM learning_sync_writers WHERE user_id = $1 AND retired_at IS NOT NULL ORDER BY retired_at, writer_id`, u.ID)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		for rows.Next() {
			var id uuid.UUID
			_ = rows.Scan(&id)
			out = append(out, id)
		}
		return out
	}
	reg()
	if got := retired(); len(got) != 1 || got[0] != w[2] {
		t.Fatalf("first retirement: %v, want %v", got, w[2])
	}
	reg()
	if got := retired(); len(got) != 2 || got[1] != w[0] {
		t.Fatalf("second retirement: %v, want %v next", got, w[0])
	}
	// Concurrent 21st and 22nd registrations leave exactly 20 active.
	mustExec(t, e.d.Pool, `DELETE FROM rate_limit_counters WHERE key LIKE 'learning_writer:%'`)
	var wg sync.WaitGroup
	for range 2 {
		wg.Add(1)
		go func() { defer wg.Done(); e.post(t, pathLWriters, map[string]any{}, bearer(keep.access)...) }()
	}
	wg.Wait()
	if n := rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_sync_writers WHERE user_id = $1 AND retired_at IS NULL`, u.ID); n != 20 {
		t.Fatalf("active after concurrent registrations: %d", n)
	}
	// last_used_at moves on a 200 push only.
	at := func() string {
		var s string
		_ = e.d.Pool.QueryRow(context.Background(), `SELECT last_used_at::text FROM learning_sync_writers WHERE writer_id = $1`, keep.writer).Scan(&s)
		return s
	}
	before := at()
	keep.state(t)
	keep.changes(t, keep.mustSnapshotCursor(t))
	keep.push(t, mDelete(keep.seq+5, uuid.New(), 0)) // refused: sequence_gap
	if at() != before {
		t.Fatal("reads and refused pushes must not touch last_used_at")
	}
	keep.mustPush(t, mCreate(keep.next(), uuid.New(), wordData("w")))
	if at() == before {
		t.Fatal("a 200 push touches last_used_at")
	}
	// A retired writer is refused at once; its state reads inactive; sessions are untouched.
	victim := e.device(t, u, "victim")
	for range 1200 / 200 {
		muts := make([]map[string]any, 200)
		for i := range muts {
			muts[i] = mDelete(victim.next(), uuid.New(), 0)
		}
		victim.mustPush(t, muts...)
	}
	mustExec(t, e.d.Pool, `UPDATE learning_sync_writers SET last_used_at = '1990-01-01' WHERE writer_id = $1`, victim.writer)
	reg()
	r, _ := victim.push(t, mDelete(victim.next(), uuid.New(), 0))
	wantProblem(t, r, http.StatusGone, "sync_reset_required")
	if r.str("reason") != "writer_unknown" || victim.state(t).Writer.Active {
		t.Fatalf("retired writer: %s", r.raw)
	}
	wantStatus(t, e.me(t, victim.access), http.StatusOK)
	// History is deleted in bounded batches, then the empty writer; an interrupted run resumes.
	if err := cascadeRefused(e, `DELETE FROM learning_sync_writers WHERE writer_id = $1`, victim.writer); err == nil {
		t.Fatal("a writer with records must not cascade them away")
	}
	res := e.learningCleanup(t, 500, 1)
	if res.Err != nil || rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_mutations WHERE writer_id = $1`, victim.writer) != 700 {
		t.Fatalf("one bounded batch: %+v", res)
	}
	mustExec(t, e.d.Pool, `CREATE FUNCTION fail_writer_delete() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic cleanup failure'; END $$`)
	mustExec(t, e.d.Pool, `CREATE TRIGGER fail_writer_delete BEFORE DELETE ON learning_sync_writers FOR EACH ROW EXECUTE FUNCTION fail_writer_delete()`)
	if res := e.learningCleanup(t, 1000, 5); res.Err == nil {
		t.Fatal("failure not exercised")
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_mutations WHERE writer_id = $1`, victim.writer) != 0 ||
		rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_sync_writers WHERE writer_id = $1`, victim.writer) != 1 {
		t.Fatal("history must be gone before the writer, and the writer kept after a failure")
	}
	mustExec(t, e.d.Pool, `DROP TRIGGER fail_writer_delete ON learning_sync_writers`)
	if res := e.learningCleanup(t, 1000, 5); res.Err != nil || rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_sync_writers WHERE writer_id = $1`, victim.writer) != 0 {
		t.Fatalf("resume: %+v", res)
	}
	// Revoking every session (TRD 02 logout-all) retires no writer.
	active := rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_sync_writers WHERE user_id = $1 AND retired_at IS NULL`, u.ID)
	want204(t, e.send(t, http.MethodDelete, "/v1/me/sessions", nil, bearer(keep.access)...))
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_sync_writers WHERE user_id = $1 AND retired_at IS NULL`, u.ID) != active {
		t.Fatal("session revocation must not retire writers")
	}
	// Another owner's writer id is unknown to this owner.
	stranger := e.device(t, newUser(t, e.q), "S")
	b := stranger.body(mDelete(1, uuid.New(), 0))
	b["writer_id"] = keep.writer
	rs := e.post(t, pathLPush, b, bearer(stranger.access)...)
	if rs.str("reason") != "writer_unknown" {
		t.Fatalf("foreign writer: %s", rs.raw)
	}
}

func cascadeRefused(e *signupEnv, sql string, args ...any) error {
	_, err := e.d.Pool.Exec(context.Background(), sql, args...)
	return err
}

// Every multi-row learning table is RESTRICT from its parent: a user or writer delete cannot
// cascade an unbounded number of rows; the head (one row) is the only cascade.
func TestLearningSync_NoUnboundedCascade(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	u := newUser(t, e.q)
	d := e.device(t, u, "D")
	d.mustPush(t, mCreate(d.next(), uuid.New(), wordData("w")))
	_, err := e.d.Pool.Exec(context.Background(), `DELETE FROM users WHERE id = $1`, u.ID)
	var pg *pgconn.PgError
	if !errors.As(err, &pg) || pg.Code != "23503" || !strings.HasPrefix(pg.ConstraintName, "learning_") && !strings.HasPrefix(pg.ConstraintName, "vocabulary_items_") {
		t.Fatalf("a user with learning rows must not delete: %v", err)
	}
	mustExec(t, e.d.Pool, `DELETE FROM vocabulary_items WHERE user_id = $1`, u.ID)
	_, err = e.d.Pool.Exec(context.Background(), `DELETE FROM learning_sync_writers WHERE user_id = $1`, u.ID)
	wantPgError(t, err, "23503", "learning_mutations_user_id_writer_id_fkey")
	var restrict int
	if err := e.d.Pool.QueryRow(context.Background(), `SELECT count(*) FROM pg_constraint WHERE contype = 'f' AND confdeltype = 'c'
		AND conrelid::regclass::text IN ('vocabulary_items','learning_mutations','learning_sync_writers','account_export_chunks')`).Scan(&restrict); err != nil || restrict != 0 {
		t.Fatalf("multi-row learning tables must not cascade: %d %v", restrict, err)
	}
	// A fresh user with no learning rows still deletes, cascading only its one head row.
	v := newUser(t, e.q)
	mustExec(t, e.d.Pool, `DELETE FROM users WHERE id = $1`, v.ID)
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_sync_heads WHERE user_id = $1`, v.ID) != 0 {
		t.Fatal("the head cascades")
	}
}

// D6, §8.2: the restore runbook's sync steps. While closed every route is 503; after the epoch
// rotation and logical writer retirement, every device's cursor and writer are refused, history
// drains in bounded batches, and a full snapshot works under the new epoch.
func TestLearningSync_RestoreRunbook(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	u := newUser(t, e.q)
	d := e.device(t, u, "D")
	d.mustPush(t, mCreate(d.next(), uuid.New(), wordData("before restore")))
	_, s := d.snapshot(t, "", 10)
	// A rewound head under the same epoch is caught defensively.
	mustExec(t, e.d.Pool, `UPDATE learning_sync_heads SET revision = 0 WHERE user_id = $1`, u.ID)
	rc, _ := d.changes(t, s.CatchUpCursor)
	if rc.str("reason") != "cursor_ahead" {
		t.Fatalf("rewound head: %s", rc.raw)
	}
	mustExec(t, e.d.Pool, `UPDATE learning_sync_heads SET revision = 1 WHERE user_id = $1`, u.ID)
	// Runbook step 2: close sync.
	mustExec(t, e.d.Pool, `UPDATE learning_sync_control SET open = false, changed_at = now()`)
	wantProblem(t, e.get(t, pathLState, bearer(d.access)...), http.StatusServiceUnavailable, "sync_unavailable")
	// Step 4: rotate every epoch and retire every writer logically.
	mustExec(t, e.d.Pool, `UPDATE learning_sync_heads SET epoch = gen_random_uuid()`)
	mustExec(t, e.d.Pool, `UPDATE learning_sync_writers SET retired_at = now() WHERE retired_at IS NULL`)
	// Step 6: reopen.
	e.openSync(t)
	rc, _ = d.changes(t, s.CatchUpCursor)
	if rc.str("reason") != "epoch_changed" {
		t.Fatalf("old cursor after restore: %s", rc.raw)
	}
	old := d.body(mDelete(d.seq+1, uuid.New(), 0))
	old["epoch"] = uuid.MustParse(rc.str("epoch"))
	if r := e.post(t, pathLPush, old, bearer(d.access)...); r.str("reason") != "writer_unknown" {
		t.Fatalf("old writer after restore: %s", r.raw)
	}
	if res := e.learningCleanup(t, 1000, 5); res.Err != nil || rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_sync_writers WHERE user_id = $1`, u.ID) != 0 {
		t.Fatalf("retired writers drain: %+v", res)
	}
	d.register(t)
	if view, _ := d.fullSync(t); len(view) != 1 {
		t.Fatalf("snapshot under the new epoch: %d", len(view))
	}
}
