package learning

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/httpx"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const MaxCartridges = 16
const MaxCartridgeBytes = 1 << 20

var cartridgeID = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,47}$`)
var cartridgeTicket = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$`)
var ErrPlanRequired = errors.New("cartridges: premium required")
var ErrCartridgeNotFound = errors.New("cartridges: not found")
var ErrInvalidCartridge = errors.New("cartridges: invalid publication")

// CartridgeDocument is the immutable publishing and download format. Raw content is decoded
// through the existing strict vocabulary decoder, including invalid UTF-8/surrogate detection.
type CartridgeDocument struct {
	ID           string           `json:"id"`
	Title        string           `json:"title"`
	Version      int32            `json:"version"`
	RequiredPlan string           `json:"required_plan"`
	Entries      []CartridgeEntry `json:"entries"`
}
type CartridgeEntry struct {
	EntryID uuid.UUID       `json:"entry_id"`
	Content json.RawMessage `json:"content"`
}

func ValidCartridgeID(id string) bool { return cartridgeID.MatchString(id) }

func decodeCartridge(raw []byte) (CartridgeDocument, map[uuid.UUID]Content, error) {
	var d CartridgeDocument
	if len(raw) > MaxCartridgeBytes || !utf8.Valid(raw) || httpx.DecodeObject(raw, &d) != nil || !ValidCartridgeID(d.ID) || d.Version < 1 ||
		d.RequiredPlan != "free" && d.RequiredPlan != "premium" || strings.TrimSpace(d.Title) == "" || utf8.RuneCountInString(d.Title) > 100 ||
		len(d.Entries) < 1 || len(d.Entries) > MaxMutations {
		return d, nil, ErrInvalidCartridge
	}
	// Validate the raw title too: json.Unmarshal otherwise repairs lone surrogates silently.
	var fields map[string]json.RawMessage
	_ = json.Unmarshal(raw, &fields)
	if _, bad, err := jsonString(fields["title"]); bad != nil || err != nil {
		return d, nil, ErrInvalidCartridge
	}
	for _, r := range d.Title {
		if r < 0x20 {
			return d, nil, ErrInvalidCartridge
		}
	}
	var rawEntries []json.RawMessage
	if json.Unmarshal(fields["entries"], &rawEntries) != nil {
		return d, nil, ErrInvalidCartridge
	}
	items := map[uuid.UUID]Content{}
	for i, e := range d.Entries {
		var strict CartridgeEntry
		if httpx.DecodeObject(rawEntries[i], &strict) != nil {
			return d, nil, ErrInvalidCartridge
		}
		var entryFields map[string]json.RawMessage
		_ = json.Unmarshal(rawEntries[i], &entryFields)
		entryID, bad, err := jsonString(entryFields["entry_id"])
		if err != nil || bad != nil || entryID != e.EntryID.String() {
			return d, nil, ErrInvalidCartridge
		}
		if e.EntryID == uuid.Nil {
			return d, nil, ErrInvalidCartridge
		}
		if _, ok := items[e.EntryID]; ok {
			return d, nil, ErrInvalidCartridge
		}

		body := append([]byte(nil), e.Content...)
		body = []byte(strings.TrimSpace(string(body)))
		if len(body) < 2 || body[len(body)-1] != '}' {
			return d, nil, ErrInvalidCartridge
		}
		body = append(body[:len(body)-1], `,"capture_day":"2026-01-01","client_created_at":"2026-01-01T00:00:00Z"}`...)
		it, bad, badDate, err := decodeItem(body)
		if err != nil || bad != nil || it.Validate(badDate) != nil {
			return d, nil, ErrInvalidCartridge
		}
		items[e.EntryID] = it.Content
	}
	return d, items, nil
}

// PublishCartridge is operator-only, authenticated by database access. No HTTP route calls it.
// Identical bytes are a no-op. Every inserted version and its minimized CLI audit commit together.
func PublishCartridge(ctx context.Context, pool *pgxpool.Pool, raw []byte, ticket string) (bool, error) {
	d, _, err := decodeCartridge(raw)
	if err != nil || !cartridgeTicket.MatchString(ticket) {
		return false, ErrInvalidCartridge
	}
	for _, p := range []string{"vat_", "vrt_", "vct_", "vop_"} {
		if strings.Contains(strings.ToLower(ticket), p) {
			return false, ErrInvalidCartridge
		}
	}
	digest := sha256.Sum256(raw)
	changed := false
	err = (db.Tx{Pool: pool}).Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		changed = false
		q := sqlc.New(tx)
		if err := q.CartridgePublishLock(ctx); err != nil {
			return err
		}
		old, err := q.GetCartridgeVersion(ctx, sqlc.GetCartridgeVersionParams{CartridgeID: d.ID, Version: d.Version})
		if err == nil {
			if old.Sha256 == hex.EncodeToString(digest[:]) {
				return nil
			}
			return ErrInvalidCartridge
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		pack, err := q.GetCartridge(ctx, d.ID)
		if errors.Is(err, pgx.ErrNoRows) {
			n, err := q.CountCartridges(ctx)
			if err != nil {
				return err
			}
			if n >= MaxCartridges || d.Version != 1 {
				return ErrInvalidCartridge
			}
			if err := q.InsertCartridge(ctx, sqlc.InsertCartridgeParams{ID: d.ID, RequiredPlan: d.RequiredPlan}); err != nil {
				return err
			}
		} else if err != nil {
			return err
		} else {
			last, err := q.LatestCartridgeVersion(ctx, d.ID)
			if err != nil {
				return err
			}
			if pack.RequiredPlan != d.RequiredPlan || int64(d.Version) != int64(last.Version)+1 {
				return ErrInvalidCartridge
			}
		}
		entries, err := q.ListCartridgeEntries(ctx, d.ID)
		if err != nil {
			return err
		}
		seen := map[uuid.UUID]bool{}
		for _, e := range d.Entries {
			seen[e.EntryID] = true
		}
		for _, e := range entries {
			if !seen[e.EntryID] {
				return ErrInvalidCartridge
			}
			delete(seen, e.EntryID)
		}
		if err := q.InsertCartridgeVersion(ctx, sqlc.InsertCartridgeVersionParams{CartridgeID: d.ID, Version: d.Version, Title: d.Title, WordCount: int32(len(d.Entries)), Sha256: hex.EncodeToString(digest[:]), Document: raw}); err != nil {
			return err
		}
		for id := range seen {
			if err := q.InsertCartridgeEntry(ctx, sqlc.InsertCartridgeEntryParams{CartridgeID: d.ID, EntryID: id, FirstVersion: d.Version}); err != nil {
				return err
			}
		}
		if err := audit.Record(ctx, tx, audit.Event{Action: "cartridge.publish", Outcome: audit.Success, Reason: "publish", Metadata: map[string]string{"source": "cli", "cartridge_id": d.ID, "version": strconv.Itoa(int(d.Version)), "ticket_ref": ticket}}); err != nil {
			return err
		}
		changed = true
		return nil
	})
	return changed, err
}

type CatalogEntry struct {
	ID               string `json:"id"`
	Title            string `json:"title"`
	Version          int32  `json:"version"`
	RequiredPlan     string `json:"required_plan"`
	WordCount        int32  `json:"word_count"`
	SHA256           string `json:"sha256"`
	InstalledVersion int32  `json:"installed_version"`
}

func (s *Service) CartridgeCatalog(ctx context.Context, p session.Principal) ([]CatalogEntry, error) {
	rows, err := sqlc.New(s.pool).ListCartridgeCatalog(ctx, p.UserID)
	if err != nil {
		return nil, err
	}
	out := make([]CatalogEntry, 0, len(rows))
	for _, r := range rows {
		out = append(out, CatalogEntry{r.ID, r.Title, r.Version, r.RequiredPlan, r.WordCount, r.Sha256, r.InstalledVersion})
	}
	return out, nil
}
func authorizeCartridge(ctx context.Context, q *sqlc.Queries, user uuid.UUID, plan string) error {
	effective, err := q.EffectiveEntitlement(ctx, user)
	if err != nil {
		return err
	}
	if plan == "premium" && !effective.Premium {
		return ErrPlanRequired
	}
	return nil
}
func (s *Service) CartridgeContent(ctx context.Context, p session.Principal, id string, v int32) ([]byte, error) {
	// Content is immutable; evaluate entitlement at database time after the lookup and before
	// returning any bytes. No cached authorization.
	q := sqlc.New(s.pool)
	r, err := q.GetCartridgeVersion(ctx, sqlc.GetCartridgeVersionParams{CartridgeID: id, Version: v})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrCartridgeNotFound
	}
	if err != nil {
		return nil, err
	}
	if err := authorizeCartridge(ctx, q, p.UserID, r.RequiredPlan); err != nil {
		return nil, err
	}
	return r.Document, nil
}

type CartridgeInstallInput struct {
	Epoch         uuid.UUID `json:"epoch"`
	CapacityBasis Basis     `json:"capacity_basis"`
}
type CartridgeInstallResult struct {
	InstalledVersion int32 `json:"installed_version"`
	Added            int   `json:"added"`
	HeadRevision     int64 `json:"head_revision"`
}

// CartridgeWordID is stable across versions, devices and retries (owner-scoped by TRD 05).
func CartridgeWordID(pack string, entry uuid.UUID) uuid.UUID {
	return uuid.NewSHA1(uuid.NameSpaceURL, []byte("veea:cartridge:"+pack+":"+entry.String()))
}

func (s *Service) InstallCartridge(ctx context.Context, p session.Principal, id string, v int32, in CartridgeInstallInput) (CartridgeInstallResult, error) {
	if err := s.admit(ctx, p, rulePush); err != nil {
		return CartridgeInstallResult{}, err
	}
	var out CartridgeInstallResult
	err := s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		out = CartridgeInstallResult{}
		head, err := lockOwner(ctx, tx, p)
		if err != nil {
			return err
		}
		if head.Epoch != in.Epoch {
			return s.reset("epoch_changed", head.Epoch)
		}
		q := sqlc.New(tx)
		doc, err := q.GetCartridgeVersion(ctx, sqlc.GetCartridgeVersionParams{CartridgeID: id, Version: v})
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrCartridgeNotFound
		}
		if err != nil {
			return err
		}
		installed, err := q.GetCartridgeInstallation(ctx, sqlc.GetCartridgeInstallationParams{UserID: p.UserID, CartridgeID: id})
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		out.InstalledVersion, out.HeadRevision = installed, head.Revision
		if installed >= v {
			return nil
		}
		if err := authorizeCartridge(ctx, q, p.UserID, doc.RequiredPlan); err != nil {
			return err
		}
		d, contents, err := decodeCartridge(doc.Document)
		if err != nil {
			return err
		}
		entries, err := q.ListCartridgeEntries(ctx, id)
		if err != nil {
			return err
		}
		first := map[uuid.UUID]int32{}
		for _, e := range entries {
			first[e.EntryID] = e.FirstVersion
		}
		now, err := q.WallClock(ctx)
		if err != nil {
			return err
		}
		day := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
		ms := make([]Mutation, 0, len(d.Entries))
		for _, e := range d.Entries {
			if first[e.EntryID] <= installed {
				continue
			}
			it := Item{Content: contents[e.EntryID], CaptureDay: day, ClientCreatedAt: now}
			ms = append(ms, Mutation{Op: OpCreate, EntityID: CartridgeWordID(id, e.EntryID), Item: &it})
		}
		c := counters{head.Revision, head.LiveWords, head.ContentBytes}
		if len(ms) > 0 {
			if err := admitImport(ctx, q, p.UserID, in.CapacityBasis, c, ms, 0); err != nil {
				return err
			}
		}
		for _, m := range ms {
			r, err := s.apply(ctx, q, p.UserID, head, &c, m)
			if err != nil {
				return err
			}
			if r.Outcome == "applied" {
				out.Added++
			} else if r.Code != "id_in_use" {
				return fmt.Errorf("cartridges: validated import refused")
			}
		}
		if err := q.UpdateLearningHead(ctx, sqlc.UpdateLearningHeadParams{UserID: p.UserID, Revision: c.revision, LiveWords: c.liveWords, ContentBytes: c.contentBytes}); err != nil {
			return err
		}
		if err := q.SetCartridgeInstallation(ctx, sqlc.SetCartridgeInstallationParams{UserID: p.UserID, CartridgeID: id, InstalledVersion: v}); err != nil {
			return err
		}
		out.InstalledVersion, out.HeadRevision = v, c.revision
		return nil
	})
	return out, err
}

// AppendCartridgeInstallations appends the exact bounded owner-export section (at most 16).
func AppendCartridgeInstallations(dst []byte, rows []sqlc.ListCartridgeInstallationsRow) []byte {
	dst = append(dst, `,"cartridge_installations":[`...)
	for i, r := range rows {
		if i > 0 {
			dst = append(dst, ',')
		}
		dst = append(dst, `{"cartridge_id":`...)
		dst = appendString(dst, r.CartridgeID)
		dst = append(dst, `,"installed_version":`...)
		dst = strconv.AppendInt(dst, int64(r.InstalledVersion), 10)
		dst = append(dst, '}')
	}
	return append(dst, ']')
}
