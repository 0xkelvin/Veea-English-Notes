// Package lifecycle implements TRD 04 owner-scoped state changes and mailbox-proven rights.
package lifecycle

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"io"
	"net"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/otp"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity/accounts"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/clientip"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/metrics"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/ratelimit"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrNotFound = errors.New("rights operation not found")
	ErrConflict = errors.New("lifecycle conflict")
	ErrNotReady = errors.New("export not ready")
	ErrExpired  = errors.New("export expired")
	ErrCanceled = errors.New("operation canceled")
)

type Service struct {
	pool    *pgxpool.Pool
	tx      db.Tx
	otp     *otp.Service
	keys    *notify.Keyring
	email   *identity.EmailHMAC
	metrics *metrics.Metrics
	limiter *ratelimit.Limiter
	// exportTimeout bounds one export generation; zero means DefaultExportTimeout.
	exportTimeout time.Duration
}

func New(pool *pgxpool.Pool, o *otp.Service, keys *notify.Keyring, email *identity.EmailHMAC, m *metrics.Metrics, onRetry func(string)) *Service {
	return &Service{pool: pool, tx: db.Tx{Pool: pool, OnRetry: onRetry}, otp: o, keys: keys, email: email, metrics: m, limiter: ratelimit.NewLimiter(pool)}
}
func purpose(action string) (otp.Purpose, error) {
	switch action {
	case "export":
		return otp.PurposeAccountExport, nil
	case "delete":
		return otp.PurposeAccountDelete, nil
	case "reactivate":
		return otp.PurposeAccountReactivate, nil
	}
	return "", ErrNotFound
}
func eligible(action string, u sqlc.User) bool {
	if u.EmailVerifiedAt == nil {
		return false
	}
	if action == "reactivate" {
		return u.Status == "deactivated"
	}
	return u.Status == "active" || u.Status == "deactivated" || u.Status == "suspended"
}
func evidence(c session.Client, user *uuid.UUID, action string, meta map[string]string) audit.Event {
	return audit.Event{Action: action, Outcome: audit.Success, ActorUserID: user, TargetUserID: user, IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID, Metadata: meta}
}

type Started struct {
	OperationID    uuid.UUID
	OperationToken string
	Proof          otp.Acknowledgement
}

func (s *Service) Start(ctx context.Context, action, raw string, c session.Client) (Started, error) {
	p, err := purpose(action)
	if err != nil {
		return Started{}, err
	}
	email, err := identity.NormalizeEmail(raw)
	if err != nil {
		return Started{}, err
	}
	id, err := uuid.NewV7()
	if err != nil {
		return Started{}, errors.New("rights: generate operation")
	}
	artifact, err := uuid.NewV7()
	if err != nil {
		return Started{}, errors.New("rights: generate artifact")
	}
	var b [32]byte
	if _, err := io.ReadFull(rand.Reader, b[:]); err != nil {
		return Started{}, errors.New("rights: generate capability")
	}
	token := "vop_" + base64.RawURLEncoding.EncodeToString(b[:])
	ack, err := s.otp.Start(ctx, otp.StartRequest{Purpose: p, OperationID: &id, Email: email, IP: requestIP(c), UserAgent: c.UserAgent, RequestID: c.RequestID,
		Check: func(ctx context.Context, tx pgx.Tx) (otp.Target, error) {
			u, ok, err := accounts.Find(ctx, tx, email)
			if err != nil || !ok || !eligible(action, u) {
				return otp.Target{}, err
			}
			return otp.Target{Eligible: true, UserID: &u.ID, To: u.Email, EmailRevision: u.EmailRevision, LifecycleRevision: u.LifecycleRevision}, nil
		},
		AfterStart: func(ctx context.Context, tx pgx.Tx, t otp.Target, ch uuid.UUID, expires time.Time) error {
			return sqlc.New(tx).InsertAccountOperation(ctx, sqlc.InsertAccountOperationParams{ID: id, TokenHash: otp.HashToken(token), Action: action, UserID: t.UserID, ChallengeID: ch, EmailRevision: t.EmailRevision, LifecycleRevision: t.LifecycleRevision, ProofExpiresAt: expires, ArtifactID: artifact})
		},
	})
	if err != nil {
		return Started{}, err
	}
	return Started{OperationID: id, OperationToken: token, Proof: ack}, nil
}

// Lookup authenticates only an action-scoped capability. It never accepts session tokens.
func (s *Service) Lookup(ctx context.Context, action string, id uuid.UUID, token string, c session.Client) (sqlc.AccountOperation, error) {
	if _, err := purpose(action); err != nil {
		return sqlc.AccountOperation{}, err
	}
	// Count invalid tokens against the caller IP too, before looking up a capability.
	d, err := s.limiter.Allow(ctx, ratelimit.Check{Rule: ratelimit.Rule{Name: "rights_request_ip", Limit: 300, Window: time.Minute}, Subject: ratelimit.IPSubject(requestIP(c))})
	if err != nil {
		return sqlc.AccountOperation{}, err
	}
	if err := d.Err(); err != nil {
		return sqlc.AccountOperation{}, err
	}
	op, err := sqlc.New(s.pool).GetAccountOperation(ctx, sqlc.GetAccountOperationParams{ID: id, Action: action, TokenHash: otp.HashToken(token)})
	if errors.Is(err, pgx.ErrNoRows) {
		return op, ErrNotFound
	}
	if err != nil {
		return op, err
	}
	d, err = s.limiter.Allow(ctx, ratelimit.Check{Rule: ratelimit.Rule{Name: "rights_operation", Limit: 30, Window: time.Minute}, Subject: ratelimit.SessionSubject(op.ID)})
	if err != nil {
		return op, err
	}
	return op, d.Err()
}

func (s *Service) Complete(ctx context.Context, op sqlc.AccountOperation, token, code string, c session.Client) error {
	if op.AcceptedAt != nil {
		return nil
	}
	p, err := purpose(op.Action)
	if err != nil {
		return err
	}
	var signupLocks []uuid.UUID
	req := otp.VerifyRequest{Purpose: p, Token: token, Code: code, OperationID: &op.ID, IP: requestIP(c), UserAgent: c.UserAgent, RequestID: c.RequestID}
	if op.Action == "delete" && op.UserID != nil {
		u, ok, err := accounts.Get(ctx, s.pool, *op.UserID)
		if err != nil {
			return err
		}
		if ok {
			req.BeforeLock = func(ctx context.Context, tx pgx.Tx) error {
				if err := otp.LockAddresses(ctx, tx, u.EmailNormalized); err != nil {
					return err
				}
				var err error
				signupLocks, err = otp.LockDeletionProofs(ctx, tx, u.EmailNormalized, token)
				return err
			}
		}
	}
	var revoked int64
	var accepted bool
	err = s.otp.Verify(ctx, req, func(ctx context.Context, tx pgx.Tx, a otp.Accepted) error {
		revoked, accepted = 0, false
		q := sqlc.New(tx)
		current, err := q.LockAccountOperation(ctx, op.ID)
		if err != nil {
			return err
		}
		if current.AcceptedAt != nil {
			return nil
		}
		if op.Action == "delete" { // L2s after L2b, before L3 (TRD 06 §4.4)
			if err := accounts.LockSuperAdminGuard(ctx, tx); err != nil {
				return err
			}
		}
		if a.UserID == nil || op.UserID == nil || *a.UserID != *op.UserID || a.ChallengeID != op.ChallengeID {
			return otp.Rollback("binding_invalid", otp.ErrInvalidCode)
		}
		u, ok, err := accounts.LockForNoKeyUpdate(ctx, tx, *op.UserID)
		if err != nil {
			return err
		}
		if !ok || !eligible(op.Action, u) || !otp.MatchesAccount(a, u) || op.EmailRevision != u.EmailRevision || op.LifecycleRevision != u.LifecycleRevision {
			return otp.Rollback("lifecycle_changed", ErrConflict)
		}
		if op.Action == "delete" {
			if err := accounts.CheckNotLastSuperAdmin(ctx, tx, u); errors.Is(err, accounts.ErrLastSuperAdmin) {
				return otp.Rollback("last_super_admin", err) // the proof stays usable
			} else if err != nil {
				return err
			}
		}
		state := "pending"
		digests := [][]byte{}
		switch op.Action {
		case "reactivate":
			state = "completed"
			if err := accounts.SetState(ctx, tx, u.ID, "active"); err != nil {
				return err
			}
			reason := "account_inactive"
			revoked, err = q.RevokeAllSessionsForUser(ctx, sqlc.RevokeAllSessionsForUserParams{UserID: u.ID, Reason: &reason})
			if err != nil {
				return err
			}
			if err := cancelExports(ctx, tx, c, u.ID); err != nil {
				return err
			}
		case "export":
			recent, err := q.HasRecentExport(ctx, &u.ID)
			if err != nil {
				return err
			}
			if recent {
				return otp.Rollback("export_limit", ErrConflict)
			}
		case "delete":
			if err := otp.InvalidateSignup(ctx, tx, signupLocks); err != nil {
				return err
			}
			if err := accounts.SetState(ctx, tx, u.ID, "pending_deletion"); err != nil {
				return err
			}
			reason := "account_delete"
			revoked, err = q.RevokeAllSessionsForUser(ctx, sqlc.RevokeAllSessionsForUserParams{UserID: u.ID, Reason: &reason})
			if err != nil {
				return err
			}
			if err := cancelExports(ctx, tx, c, u.ID); err != nil {
				return err
			}
			if err := otp.CancelLockedSignupMail(ctx, tx, signupLocks); err != nil {
				return err
			}
			digests = s.email.All(a.Email)
			for _, h := range digests {
				if err := q.FenceDeletedAddress(ctx, h); err != nil {
					return err
				}
			}
			if err := q.InsertDeletionLedger(ctx, sqlc.InsertDeletionLedgerParams{OperationID: op.ID, UserID: u.ID}); err != nil {
				return err
			}
			if err := audit.Record(ctx, tx, evidence(c, &u.ID, "auth.session.revoke", map[string]string{"reason": reason, "count": formatCount(revoked)})); err != nil {
				return err
			}
		}
		if op.Action == "reactivate" && revoked > 0 {
			if err := audit.Record(ctx, tx, evidence(c, &u.ID, "auth.session.revoke", map[string]string{"reason": "account_inactive", "count": formatCount(revoked)})); err != nil {
				return err
			}
		}
		if err := q.AcceptAccountOperation(ctx, sqlc.AcceptAccountOperationParams{ID: op.ID, State: state, EmailDigests: digests}); err != nil {
			return err
		}
		accepted = true
		action := "account." + op.Action + ".request"
		if op.Action == "reactivate" {
			action = "account.reactivate"
		}
		return audit.Record(ctx, tx, evidence(c, &u.ID, action, map[string]string{"operation_id": op.ID.String()}))
	})
	if err != nil { // A concurrent identical completion may already have consumed its proof.
		current, rerr := sqlc.New(s.pool).ReadAccountOperation(ctx, op.ID)
		if rerr == nil && current.AcceptedAt != nil {
			return nil
		}
		return err
	}
	if !accepted { // an identical completion committed first; it counted itself
		return nil
	}
	s.metrics.LifecycleAccepted(op.Action)
	if op.Action == "delete" {
		s.metrics.SessionsRevoked("account_delete", revoked)
	} else if op.Action == "reactivate" {
		s.metrics.SessionsRevoked("account_inactive", revoked)
	}
	return nil
}

// cancelExports ends every pending or ready export of the owner inside the caller's
// transition, discarding any artifact, with one account.export.cancel event per operation.
func cancelExports(ctx context.Context, tx pgx.Tx, c session.Client, user uuid.UUID) error {
	return CancelExports(ctx, tx, c, user, user)
}

// CancelExports is cancelExports for a transition made by another actor, such as an admin
// suspension (TRD 06 §5.2): each account.export.cancel event names actor, with owner as target.
func CancelExports(ctx context.Context, tx pgx.Tx, c session.Client, actor, user uuid.UUID) error {
	ids, err := sqlc.New(tx).CancelAccountExports(ctx, &user)
	if err != nil {
		return err
	}
	if err := sqlc.New(tx).DeleteExportChunks(ctx, ids); err != nil {
		return err
	}
	for _, id := range ids {
		ev := evidence(c, &user, "account.export.cancel", map[string]string{"operation_id": id.String()})
		ev.ActorUserID = &actor
		if err := audit.Record(ctx, tx, ev); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) Deactivate(ctx context.Context, p session.Principal, revision int64, c session.Client) error {
	var n int64
	err := s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		n = 0
		if err := accounts.LockSuperAdminGuard(ctx, tx); err != nil { // L2s before L3 (TRD 06 §4.4)
			return err
		}
		u, ok, err := accounts.LockForNoKeyUpdate(ctx, tx, p.UserID)
		if err != nil {
			return err
		}
		if !ok || !accounts.InGoodStanding(u) {
			return session.ErrUnauthorized
		}
		if _, ok, err := session.LockActing(ctx, tx, p.UserID, p.SessionID); err != nil {
			return err
		} else if !ok {
			return session.ErrUnauthorized
		}
		if u.LifecycleRevision != revision {
			return ErrConflict
		}
		if err := accounts.CheckNotLastSuperAdmin(ctx, tx, u); err != nil {
			return err
		}
		if err := accounts.SetState(ctx, tx, u.ID, "deactivated"); err != nil {
			return err
		}
		reason := "deactivated"
		q := sqlc.New(tx)
		n, err = q.RevokeAllSessionsForUser(ctx, sqlc.RevokeAllSessionsForUserParams{UserID: u.ID, Reason: &reason})
		if err != nil {
			return err
		}
		if err := cancelExports(ctx, tx, c, u.ID); err != nil {
			return err
		}
		ev := evidence(c, &u.ID, "auth.session.revoke", map[string]string{"reason": reason, "count": formatCount(n)})
		ev.SessionID = &p.SessionID
		if err := audit.Record(ctx, tx, ev); err != nil {
			return err
		}
		ev.Action = "account.deactivate"
		ev.Metadata = nil
		return audit.Record(ctx, tx, ev)
	})
	if err == nil {
		s.metrics.LifecycleAccepted("deactivate")
		s.metrics.SessionsRevoked("deactivated", n)
	}
	if errors.Is(err, accounts.ErrLastSuperAdmin) {
		// The refusal is evidence too; it commits on its own after the rollback.
		ev := evidence(c, &p.UserID, "account.deactivate", nil)
		ev.Outcome, ev.Reason, ev.SessionID = audit.Failure, "last_super_admin", &p.SessionID
		if aerr := audit.Record(ctx, s.pool, ev); aerr != nil {
			return aerr
		}
	}
	return err
}

// Download authorizes and audits one download of a published version-2 export. The caller
// then streams it with StreamArtifact; the audit event records the authorized initiation, not
// that bytes reached the client.
func (s *Service) Download(ctx context.Context, op sqlc.AccountOperation, c session.Client) (Artifact, error) {
	if op.AcceptedAt == nil {
		return Artifact{}, ErrNotReady
	}
	if op.Action != "export" || op.UserID == nil {
		return Artifact{}, ErrNotFound
	}
	var a Artifact
	err := s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		u, ok, err := accounts.LockForNoKeyUpdate(ctx, tx, *op.UserID)
		if err != nil {
			return err
		}
		if !ok {
			return ErrCanceled
		}
		current, err := sqlc.New(tx).ReadAccountOperation(ctx, op.ID)
		if err != nil {
			return err
		}
		now, err := sqlc.New(tx).WallClock(ctx)
		if err != nil {
			return err
		}
		if current.State == "expired" || (current.DownloadExpiresAt != nil && !current.DownloadExpiresAt.After(now)) {
			return ErrExpired
		}
		if current.State == "canceled" || u.Status == "pending_deletion" || u.EmailRevision != op.EmailRevision || u.LifecycleRevision != op.LifecycleRevision {
			return ErrCanceled
		}
		if current.State != "ready" {
			return ErrNotReady
		}
		// Version 1 artifacts were ended by migration 00011. Versions 2 and 3 (TRD 09 adds the
		// entitlements section) share the chunk format, so a version 2 export published before
		// the upgrade stays downloadable for its 24 h window.
		if current.SchemaVersion == nil || (*current.SchemaVersion != 2 && *current.SchemaVersion != 3) || current.ArtifactPlainBytes == nil {
			return ErrExpired
		}
		a = Artifact{Operation: op.ID, ID: current.ArtifactID, Size: *current.ArtifactPlainBytes}
		return audit.Record(ctx, tx, evidence(c, op.UserID, "account.export.download", map[string]string{"operation_id": op.ID.String()}))
	})
	return a, err
}

func requestIP(c session.Client) clientip.Result {
	return clientip.New(nil).Resolve(net.JoinHostPort(c.IP.String(), "0"), nil)
}
