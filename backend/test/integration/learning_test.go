//go:build integration

package integration

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// TRD 05 learning sync through the real router and PostgreSQL.

const (
	pathLState    = "/v1/learning/sync/state"
	pathLWriters  = "/v1/learning/sync/writers"
	pathLPush     = "/v1/learning/sync/push"
	pathLImport   = "/v1/learning/sync/import"
	pathLChanges  = "/v1/learning/sync/changes"
	pathLSnapshot = "/v1/learning/sync/snapshot"
)

func (e *signupEnv) openSync(t *testing.T) {
	t.Helper()
	mustExec(t, e.d.Pool, `UPDATE learning_sync_control SET open = true, changed_at = now()`)
}

type lrecord struct {
	EntityID        uuid.UUID       `json:"entity_id"`
	Revision        int64           `json:"revision"`
	Deleted         bool            `json:"deleted"`
	Content         *map[string]any `json:"content"`
	CaptureDay      *string         `json:"capture_day"`
	ClientCreatedAt *string         `json:"client_created_at"`
}

func (r lrecord) field(name string) any {
	if r.Content == nil {
		return nil
	}
	return (*r.Content)[name]
}

type lresult struct {
	Seq              int64     `json:"seq"`
	EntityID         uuid.UUID `json:"entity_id"`
	Outcome          string    `json:"outcome"`
	OriginalOutcome  string    `json:"original_outcome"`
	Code             string    `json:"code"`
	Detail           string    `json:"detail"`
	Field            string    `json:"field"`
	Limit            string    `json:"limit"`
	ConflictedFields []string  `json:"conflicted_fields"`
	Revision         *int64    `json:"revision"`
	Record           *lrecord  `json:"record"`
}

type lpushOut struct {
	Results      []lresult `json:"results"`
	HeadRevision int64     `json:"head_revision"`
	LiveWords    int64     `json:"live_words"`
	ContentBytes int64     `json:"content_bytes"`
	LastSeq      int64     `json:"last_seq"`
}

type lstate struct {
	Epoch            uuid.UUID `json:"epoch"`
	HeadRevision     int64     `json:"head_revision"`
	TombstoneHorizon int64     `json:"tombstone_horizon"`
	LiveWords        int64     `json:"live_words"`
	ContentBytes     int64     `json:"content_bytes"`
	Writer           *struct {
		WriterID uuid.UUID `json:"writer_id"`
		LastSeq  int64     `json:"last_seq"`
		Active   bool      `json:"active"`
	} `json:"writer"`
}

type lchanges struct {
	Epoch   uuid.UUID `json:"epoch"`
	Changes []lrecord `json:"changes"`
	Cursor  string    `json:"cursor"`
	HasMore bool      `json:"has_more"`
}

type lsnapshot struct {
	Epoch            uuid.UUID `json:"epoch"`
	SnapshotRevision int64     `json:"snapshot_revision"`
	Items            []lrecord `json:"items"`
	NextPageToken    *string   `json:"next_page_token"`
	CatchUpCursor    string    `json:"catch_up_cursor"`
}

func decode[T any](t *testing.T, r response) T {
	t.Helper()
	var v T
	if err := json.Unmarshal(r.raw, &v); err != nil {
		t.Fatalf("decode %T: %v: %s", v, err, r.raw)
	}
	return v
}

// device is one install signed in to one account, with its own server-issued writer.
type device struct {
	e      *signupEnv
	user   sqlc.User
	access string
	refr   string
	sid    uuid.UUID
	writer uuid.UUID
	epoch  uuid.UUID
	seq    int64
}

func (e *signupEnv) device(t *testing.T, u sqlc.User, name string) *device {
	t.Helper()
	s := e.issue(t, u, name)
	d := &device{e: e, user: u, access: s.AccessToken, refr: s.RefreshToken, sid: s.SessionID}
	d.register(t)
	return d
}

func (d *device) register(t *testing.T) {
	t.Helper()
	r := d.e.post(t, pathLWriters, map[string]any{}, bearer(d.access)...)
	wantStatus(t, r, http.StatusCreated)
	d.writer, d.epoch, d.seq = uuid.MustParse(r.str("writer_id")), uuid.MustParse(r.str("epoch")), 0
}

func (d *device) next() int64 { d.seq++; return d.seq }

func (d *device) body(muts ...map[string]any) map[string]any {
	return map[string]any{"epoch": d.epoch, "writer_id": d.writer, "mutations": muts}
}

func (d *device) push(t *testing.T, muts ...map[string]any) (response, lpushOut) {
	t.Helper()
	r := d.e.post(t, pathLPush, d.body(muts...), bearer(d.access)...)
	if r.status != http.StatusOK {
		return r, lpushOut{}
	}
	return r, decode[lpushOut](t, r)
}

func (d *device) mustPush(t *testing.T, muts ...map[string]any) lpushOut {
	t.Helper()
	r, out := d.push(t, muts...)
	wantStatus(t, r, http.StatusOK)
	return out
}

func (d *device) importWords(t *testing.T, live, bytes int64, muts ...map[string]any) response {
	t.Helper()
	b := d.body(muts...)
	b["capacity_basis"] = map[string]any{"live_words": live, "content_bytes": bytes}
	return d.e.post(t, pathLImport, b, bearer(d.access)...)
}

func (d *device) state(t *testing.T) lstate {
	t.Helper()
	r := d.e.get(t, pathLState+"?writer_id="+d.writer.String(), bearer(d.access)...)
	wantStatus(t, r, http.StatusOK)
	return decode[lstate](t, r)
}

func (d *device) changes(t *testing.T, cursor string) (response, lchanges) {
	t.Helper()
	r := d.e.get(t, pathLChanges+"?cursor="+cursor, bearer(d.access)...)
	if r.status != http.StatusOK {
		return r, lchanges{}
	}
	return r, decode[lchanges](t, r)
}

func (d *device) snapshot(t *testing.T, token string, limit int) (response, lsnapshot) {
	t.Helper()
	q := fmt.Sprintf("?limit=%d", limit)
	if token != "" {
		q += "&page_token=" + token
	}
	r := d.e.get(t, pathLSnapshot+q, bearer(d.access)...)
	if r.status != http.StatusOK {
		return r, lsnapshot{}
	}
	return r, decode[lsnapshot](t, r)
}

// fullSync downloads a snapshot and catches up from its boundary: the client's view (§8.5).
func (d *device) fullSync(t *testing.T) (map[uuid.UUID]lrecord, string) {
	t.Helper()
	view := map[uuid.UUID]lrecord{}
	token, cursor := "", ""
	for {
		r, s := d.snapshot(t, token, 500)
		wantStatus(t, r, http.StatusOK)
		for _, it := range s.Items {
			view[it.EntityID] = it
		}
		cursor = s.CatchUpCursor
		if s.NextPageToken == nil {
			break
		}
		token = *s.NextPageToken
	}
	return d.catchUp(t, view, cursor)
}

func (d *device) catchUp(t *testing.T, view map[uuid.UUID]lrecord, cursor string) (map[uuid.UUID]lrecord, string) {
	t.Helper()
	for {
		r, c := d.changes(t, cursor)
		wantStatus(t, r, http.StatusOK)
		for _, ch := range c.Changes {
			if ch.Deleted {
				delete(view, ch.EntityID)
			} else {
				view[ch.EntityID] = ch
			}
		}
		cursor = c.Cursor
		if !c.HasMore {
			return view, cursor
		}
	}
}

func wordData(word string) map[string]any {
	return map[string]any{"word": word, "meaning": "m", "pronunciation": nil, "part_of_speech": nil, "source": nil,
		"examples": []string{}, "tags": []string{}, "capture_day": "2026-11-14", "client_created_at": "2026-11-14T08:00:00.000Z"}
}

func mCreate(seq int64, id uuid.UUID, data map[string]any) map[string]any {
	return map[string]any{"seq": seq, "op": "create", "entity_id": id, "data": data}
}

func mUpdate(seq int64, id uuid.UUID, base int64, fields map[string]any) map[string]any {
	names := make([]string, 0, len(fields))
	for k := range fields {
		names = append(names, k)
	}
	sort.Strings(names)
	return map[string]any{"seq": seq, "op": "update", "entity_id": id, "base_revision": base, "changed_fields": names, "data": fields}
}

func mDelete(seq int64, id uuid.UUID, base int64) map[string]any {
	return map[string]any{"seq": seq, "op": "delete", "entity_id": id, "base_revision": base}
}

func mRestore(seq int64, id uuid.UUID, base int64, data map[string]any) map[string]any {
	return map[string]any{"seq": seq, "op": "restore", "entity_id": id, "base_revision": base, "data": data}
}

func wantOutcome(t *testing.T, r lresult, outcome, code string) {
	t.Helper()
	if r.Outcome != outcome || r.Code != code {
		t.Fatalf("seq %d: outcome %s/%s, want %s/%s (%+v)", r.Seq, r.Outcome, r.Code, outcome, code, r)
	}
}

func (e *signupEnv) headRevision(t *testing.T, u uuid.UUID) int {
	t.Helper()
	return rowCount(t, e.d.Pool, `SELECT revision FROM learning_sync_heads WHERE user_id = $1`, u)
}

// --- the closed gate, contract errors, internal errors and limits ----------------------------------

func TestLearning_ClosedUntilOpened(t *testing.T) {
	e := newSignupEnv(t, nil)
	u := newUser(t, e.q)
	s := e.issue(t, u, "A")
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_sync_control WHERE open`) != 0 {
		t.Fatal("sync must ship closed")
	}
	h := bearer(s.AccessToken)
	cur := "c1." + strings.Repeat("A", 32)
	for _, r := range []response{
		e.get(t, pathLState, h...), e.post(t, pathLWriters, map[string]any{}, h...),
		e.post(t, pathLPush, map[string]any{"epoch": uuid.New(), "writer_id": uuid.New(), "mutations": []any{mDelete(1, uuid.New(), 0)}}, h...),
		e.post(t, pathLImport, map[string]any{"epoch": uuid.New(), "writer_id": uuid.New(), "capacity_basis": map[string]any{"live_words": 0, "content_bytes": 0},
			"mutations": []any{mCreate(1, uuid.New(), wordData("w"))}}, h...),
		e.get(t, pathLChanges+"?cursor="+cur, h...), e.get(t, pathLSnapshot, h...),
	} {
		wantProblem(t, r, http.StatusServiceUnavailable, "sync_unavailable")
		if r.header.Get("Retry-After") == "" {
			t.Fatal("503 needs Retry-After")
		}
	}
	if rowCount(t, e.d.Pool, `SELECT count(*) FROM learning_sync_writers`) != 0 {
		t.Fatal("a closed gate must write nothing")
	}
}

func TestLearning_ContractErrors(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	u := newUser(t, e.q)
	d := e.device(t, u, "A")
	h := bearer(d.access)
	cur := d.state(t)
	cursor := ""
	{
		_, s := d.snapshot(t, "", 10)
		cursor = s.CatchUpCursor
	}
	// 401 without a bearer, on every route.
	for _, r := range []response{
		e.get(t, pathLState), e.post(t, pathLWriters, map[string]any{}), e.post(t, pathLPush, d.body(mDelete(1, uuid.New(), 0))),
		e.post(t, pathLImport, map[string]any{}), e.get(t, pathLChanges+"?cursor="+cursor), e.get(t, pathLSnapshot),
	} {
		wantUnauthorized(t, r)
	}
	// 415 for every body route.
	wantMediaType := func(path string) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodPost, e.srv.URL+path, strings.NewReader(`{}`))
		req.Header.Set("Authorization", "Bearer "+d.access)
		req.Header.Set("Content-Type", "text/plain")
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_ = res.Body.Close()
		if res.StatusCode != http.StatusUnsupportedMediaType {
			t.Fatalf("%s: %d, want 415", path, res.StatusCode)
		}
	}
	for _, p := range []string{pathLWriters, pathLPush, pathLImport} {
		wantMediaType(p)
	}
	// 400: query strings, malformed bodies, cursors and tokens of the wrong kind, bad limits.
	bad := []response{
		e.get(t, pathLState+"?x=1", h...), e.get(t, pathLState+"?writer_id=nope", h...),
		e.post(t, pathLWriters, map[string]any{"x": 1}, h...), e.post(t, pathLWriters+"?x=1", map[string]any{}, h...),
		e.post(t, pathLPush, map[string]any{"epoch": cur.Epoch, "writer_id": d.writer}, h...),
		e.post(t, pathLPush, d.body(), h...),
		e.post(t, pathLPush, d.body(mDelete(1, uuid.New(), 0), mDelete(3, uuid.New(), 0)), h...), // not contiguous
		e.post(t, pathLPush, d.body(map[string]any{"seq": 1, "op": "rename", "entity_id": uuid.New()}), h...),
		e.post(t, pathLPush, d.body(map[string]any{"seq": 1, "op": "create", "entity_id": uuid.New(), "data": map[string]any{"word": "w"}}), h...),
		e.post(t, pathLPush, d.body(mUpdate(1, uuid.New(), 0, map[string]any{"client_created_at": "2026-01-01T00:00:00Z"})), h...),
		e.post(t, pathLPush+"?x=1", d.body(mDelete(1, uuid.New(), 0)), h...),
		e.post(t, pathLImport, map[string]any{"epoch": cur.Epoch, "writer_id": d.writer, "capacity_basis": map[string]any{"live_words": 0, "content_bytes": 0},
			"mutations": []any{mDelete(1, uuid.New(), 0)}}, h...), // import is creates only
		e.post(t, pathLImport, d.body(mCreate(1, uuid.New(), wordData("w"))), h...), // no capacity_basis
		e.get(t, pathLChanges, h...), e.get(t, pathLChanges+"?cursor=junk", h...), e.get(t, pathLChanges+"?cursor="+cursor+"&limit=0", h...),
		e.get(t, pathLChanges+"?cursor="+cursor+"&limit=501", h...), e.get(t, pathLChanges+"?cursor="+cursor+"&cursor="+cursor, h...),
		e.get(t, pathLSnapshot+"?page_token="+cursor, h...), e.get(t, pathLSnapshot+"?page_token=", h...), e.get(t, pathLSnapshot+"?x=1", h...),
	}
	for i, r := range bad {
		if r.status != http.StatusBadRequest {
			t.Fatalf("case %d: %d %s, want 400", i, r.status, r.raw)
		}
		wantProblem(t, r, http.StatusBadRequest, "invalid_request")
	}
	// A feed cursor is not a page token, and a page token is not a cursor.
	pageToken := ""
	for range 3 {
		d.mustPush(t, mCreate(d.next(), uuid.New(), wordData("w")))
	}
	if _, s := d.snapshot(t, "", 1); s.NextPageToken != nil {
		pageToken = *s.NextPageToken
	}
	wantProblem(t, e.get(t, pathLChanges+"?cursor="+pageToken, h...), http.StatusBadRequest, "invalid_request")
	// 413: more than 200 mutations, or a body over 2 MiB.
	many := make([]map[string]any, 201)
	for i := range many {
		many[i] = mDelete(int64(i+1), uuid.New(), 0)
	}
	wantProblem(t, e.post(t, pathLPush, d.body(many...), h...), http.StatusRequestEntityTooLarge, "payload_too_large")
	huge := wordData(strings.Repeat("x", 3<<20))
	wantProblem(t, e.post(t, pathLPush, d.body(mCreate(1, uuid.New(), huge)), h...), http.StatusRequestEntityTooLarge, "payload_too_large")
	b := d.body(mCreate(1, uuid.New(), huge))
	b["capacity_basis"] = map[string]any{"live_words": 0, "content_bytes": 0}
	wantProblem(t, e.post(t, pathLImport, b, h...), http.StatusRequestEntityTooLarge, "payload_too_large")
	many2 := make([]map[string]any, 201)
	for i := range many2 {
		many2[i] = mCreate(int64(i+1), uuid.New(), wordData("w"))
	}
	wantProblem(t, d.importWords(t, 0, 0, many2...), http.StatusRequestEntityTooLarge, "payload_too_large")
	// 410: wrong epoch, unknown writer; 409: a sequence gap, for push and import.
	wrong := d.body(mDelete(d.seq+1, uuid.New(), 0))
	wrong["epoch"] = uuid.New()
	r := e.post(t, pathLPush, wrong, h...)
	wantProblem(t, r, http.StatusGone, "sync_reset_required")
	if r.str("reason") != "epoch_changed" || r.str("epoch") != cur.Epoch.String() {
		t.Fatalf("410 body: %s", r.raw)
	}
	wrong = d.body(mCreate(d.seq+1, uuid.New(), wordData("w")))
	wrong["writer_id"], wrong["capacity_basis"] = uuid.New(), map[string]any{"live_words": 3, "content_bytes": 0}
	r = e.post(t, pathLImport, wrong, h...)
	wantProblem(t, r, http.StatusGone, "sync_reset_required")
	if r.str("reason") != "writer_unknown" {
		t.Fatalf("410 body: %s", r.raw)
	}
	gap, _ := d.push(t, mDelete(d.seq+2, uuid.New(), 0))
	wantProblem(t, gap, http.StatusConflict, "sequence_gap")
	wantProblem(t, d.importWords(t, 3, 0, mCreate(d.seq+2, uuid.New(), wordData("w"))), http.StatusConflict, "sequence_gap")
	// 410 on the feed and the snapshot.
	rc, _ := d.changes(t, cursorWithRevision(t, cursor, 1<<40))
	wantProblem(t, rc, http.StatusGone, "sync_reset_required")
	other := e.device(t, newUser(t, e.q), "B")
	rs, _ := other.snapshot(t, pageToken, 1)
	wantProblem(t, rs, http.StatusGone, "sync_reset_required")
	if rs.str("reason") != "epoch_changed" {
		t.Fatalf("another account's page token: %s", rs.raw)
	}
}

func mustB64(t *testing.T, s string) []byte {
	t.Helper()
	b, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// cursorWithRevision re-encodes a cursor's revision, keeping its epoch.
func cursorWithRevision(t *testing.T, cursor string, rev int64) string {
	t.Helper()
	b := mustB64(t, strings.TrimPrefix(cursor, "c1."))
	for i := range 8 {
		b[16+i] = byte(rev >> (56 - 8*i))
	}
	return "c1." + b64(b)
}

func TestLearning_InternalErrors(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	d := e.device(t, newUser(t, e.q), "A")
	_, s := d.snapshot(t, "", 10)
	mustExec(t, e.d.Pool, `ALTER TABLE learning_sync_heads RENAME TO test_missing_heads`)
	defer mustExec(t, e.d.Pool, `ALTER TABLE test_missing_heads RENAME TO learning_sync_heads`)
	h := bearer(d.access)
	for _, r := range []response{
		e.get(t, pathLState, h...), e.post(t, pathLWriters, map[string]any{}, h...),
		e.post(t, pathLPush, d.body(mDelete(1, uuid.New(), 0)), h...), d.importWords(t, 0, 0, mCreate(1, uuid.New(), wordData("w"))),
		e.get(t, pathLChanges+"?cursor="+s.CatchUpCursor, h...), e.get(t, pathLSnapshot, h...),
	} {
		wantProblem(t, r, http.StatusInternalServerError, "internal_error")
	}
}

func TestLearning_RateLimits(t *testing.T) {
	e := newSignupEnv(t, nil)
	e.openSync(t)
	d := e.device(t, newUser(t, e.q), "A")
	_, s := d.snapshot(t, "", 10)
	d.mustPush(t, mCreate(d.next(), uuid.New(), wordData("w")))
	mustExec(t, e.d.Pool, `UPDATE rate_limit_counters SET count = 10000 WHERE key LIKE 'learning_%'`)
	h := bearer(d.access)
	for _, r := range []response{
		e.get(t, pathLState, h...), e.post(t, pathLWriters, map[string]any{}, h...),
		e.post(t, pathLPush, d.body(mDelete(d.seq+1, uuid.New(), 0)), h...), d.importWords(t, 1, 0, mCreate(d.seq+1, uuid.New(), wordData("w"))),
		e.get(t, pathLChanges+"?cursor="+s.CatchUpCursor, h...), e.get(t, pathLSnapshot, h...),
	} {
		wantProblem(t, r, http.StatusTooManyRequests, "rate_limited")
	}
}
