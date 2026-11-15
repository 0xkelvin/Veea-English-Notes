package ratelimit

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"net/netip"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// auditSuffix names the companion counter that deduplicates auth.rate_limited events.
const auditSuffix = "_audit"

// recordTimeout bounds RecordDenial, which runs detached from the request (see below).
const recordTimeout = 2 * time.Second

// RecordDenial writes the auth.rate_limited audit event for a refusal (TRD 11.1), at most once
// per rule, scope, subject and window.
//
// Every refused request is still refused; only the record is deduplicated. A flood against one
// limit adds one audit row per window, not one per request, the same reasoning that keeps
// unknown refresh tokens out of the audit log. The deduplication is a companion counter
// ("<rule>[_<scope>]_audit") in the same fixed window as the rule.
//
// The companion counter and the audit row are written in one short transaction, so a failed
// insert also gives the slot back and the next refusal in the window records instead. It runs
// detached from ctx's cancellation (with its own short timeout), so a client that disconnects
// right after being refused cannot suppress the record. It never runs inside a business
// transaction (TRD 7.1 rule 6).
//
// Two concurrent refusals serialize on the counter row: the second sees the first's committed
// count and writes nothing; if the first rolls back, the second writes the row.
//
// The subject is stored as the email HMAC, the user or the session; an IP subject is the
// event's ip. No raw email ever appears.
func (l *Limiter) RecordDenial(ctx context.Context, e *Error, ip netip.Addr, userAgent, requestID string) error {
	if e == nil || e.Rule == "" || e.Window < time.Second {
		return nil
	}
	name := e.Rule
	if e.Scope != "" {
		name += "_" + e.Scope
	}
	dedupe := Rule{Name: name + auditSuffix, Limit: 1, Window: e.Window}
	if err := dedupe.Validate(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), recordTimeout)
	defer cancel()

	tx, err := l.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("ratelimit: record denial: %w", err)
	}
	defer tx.Rollback(context.WithoutCancel(ctx))
	row, err := sqlc.New(tx).IncrementRateLimitWindow(ctx, sqlc.IncrementRateLimitWindowParams{
		Key: Check{Rule: dedupe, Subject: e.Subject}.key(), WindowSeconds: int64(e.Window / time.Second)})
	if err != nil {
		return fmt.Errorf("ratelimit: record denial: %w", err)
	}
	if row.Count != 1 {
		return nil // already recorded in this window
	}
	if err := audit.Record(ctx, tx, denialEvent(e, ip, userAgent, requestID)); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil && !errors.Is(err, pgx.ErrTxClosed) {
		return fmt.Errorf("ratelimit: record denial: %w", err)
	}
	return nil
}

func denialEvent(e *Error, ip netip.Addr, userAgent, requestID string) audit.Event {
	ev := audit.Event{
		Action: "auth.rate_limited", Outcome: audit.Failure, Reason: e.Rule,
		IP: ip, UserAgent: userAgent, RequestID: requestID,
		Metadata: map[string]string{"rule": e.Rule, "subject": e.Subject.Kind()},
	}
	if e.Scope != "" {
		ev.Metadata["scope"] = e.Scope
	}
	switch e.Subject.Kind() {
	case "email":
		if b, err := hex.DecodeString(e.Subject.Value()); err == nil {
			ev.EmailHMAC = b
		}
	case "user":
		if id, err := uuid.Parse(e.Subject.Value()); err == nil {
			ev.TargetUserID = &id
		}
	case "session":
		if id, err := uuid.Parse(e.Subject.Value()); err == nil {
			ev.SessionID = &id
		}
	}
	return ev
}
