// Package account implements own-profile updates and the TRD 03 email cutover.
package account

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"time"
	_ "time/tzdata"
	"unicode"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/text/unicode/norm"

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
)

var (
	ErrInvalidProfile   = errors.New("invalid profile")
	ErrProfileConflict  = errors.New("profile conflict")
	ErrEmailUnchanged   = errors.New("email unchanged")
	ErrEmailUnavailable = errors.New("email unavailable")
	ErrChangeNotFound   = errors.New("email change not found")
)

type Service struct {
	pool    *pgxpool.Pool
	tx      db.Tx
	otp     *otp.Service
	outbox  *notify.Outbox
	metrics *metrics.Metrics
}

func New(pool *pgxpool.Pool, o *otp.Service, box *notify.Outbox, m *metrics.Metrics, onRetry func(string)) *Service {
	return &Service{pool: pool, tx: db.Tx{Pool: pool, OnRetry: onRetry}, otp: o, outbox: box, metrics: m}
}

type Profile struct {
	DisplayName                 *string
	PreferredLanguage, TimeZone string
	DailyGoal                   int32
	ExpectedRevision            int64
}

func (p *Profile) validate() error {
	if p.DisplayName != nil {
		v := norm.NFC.String(strings.TrimSpace(*p.DisplayName))
		if !utf8.ValidString(v) || utf8.RuneCountInString(v) < 1 || utf8.RuneCountInString(v) > 64 {
			return ErrInvalidProfile
		}
		for _, r := range v {
			if unicode.IsControl(r) {
				return ErrInvalidProfile
			}
		}
		p.DisplayName = &v
	}
	if (p.PreferredLanguage != "en" && p.PreferredLanguage != "vi") || p.DailyGoal < 1 || p.DailyGoal > 1000 || p.ExpectedRevision < 0 {
		return ErrInvalidProfile
	}
	if p.TimeZone == "" || p.TimeZone == "Local" || strings.HasPrefix(p.TimeZone, "/") {
		return ErrInvalidProfile
	}
	if _, err := time.LoadLocation(p.TimeZone); err != nil {
		return ErrInvalidProfile
	}
	return nil
}

func (s *Service) UpdateProfile(ctx context.Context, p session.Principal, in Profile, c session.Client) (sqlc.User, error) {
	if err := in.validate(); err != nil {
		return sqlc.User{}, err
	}
	var out sqlc.User
	err := s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		out = sqlc.User{}
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
		if u.ProfileRevision != in.ExpectedRevision {
			return ErrProfileConflict
		}
		out = u
		changed := []string{}
		if !reflect.DeepEqual(u.DisplayName, in.DisplayName) {
			changed = append(changed, "display_name")
		}
		if u.PreferredLanguage != in.PreferredLanguage {
			changed = append(changed, "preferred_language")
		}
		if u.TimeZone != in.TimeZone {
			changed = append(changed, "time_zone")
		}
		if u.DailyGoal != in.DailyGoal {
			changed = append(changed, "daily_goal")
		}
		if len(changed) == 0 {
			return nil
		}
		out, err = accounts.UpdateProfile(ctx, tx, sqlc.UpdateProfileParams{ID: p.UserID, DisplayName: in.DisplayName, PreferredLanguage: in.PreferredLanguage, TimeZone: in.TimeZone, DailyGoal: in.DailyGoal})
		if err != nil {
			return err
		}
		return audit.Record(ctx, tx, event(p, c, "account.profile.update", map[string]string{"fields": strings.Join(changed, ","), "revision": fmt.Sprint(out.ProfileRevision)}))
	})
	return out, err
}

func event(p session.Principal, c session.Client, action string, meta map[string]string) audit.Event {
	return audit.Event{Action: action, Outcome: audit.Success, ActorUserID: &p.UserID, TargetUserID: &p.UserID, SessionID: &p.SessionID, IP: c.IP, UserAgent: c.UserAgent, RequestID: c.RequestID, Metadata: meta}
}

func (s *Service) StartEmailChange(ctx context.Context, p session.Principal, raw string, c session.Client) (otp.PairAcknowledgement, error) {
	next, err := identity.NormalizeEmail(raw)
	if err != nil {
		return otp.PairAcknowledgement{}, err
	}
	u, ok, err := accounts.Get(ctx, s.pool, p.UserID)
	if err != nil {
		return otp.PairAcknowledgement{}, err
	}
	if !ok || !accounts.InGoodStanding(u) {
		return otp.PairAcknowledgement{}, session.ErrUnauthorized
	}
	if next.Normalized == u.EmailNormalized {
		return otp.PairAcknowledgement{}, ErrEmailUnchanged
	}
	id, err := uuid.NewV7()
	if err != nil {
		return otp.PairAcknowledgement{}, errors.New("account: generate change id")
	}
	old := identity.Email{Display: u.Email, Normalized: u.EmailNormalized}
	req := func(purpose otp.Purpose, e identity.Email) otp.StartRequest {
		return otp.StartRequest{Purpose: purpose, Email: e, IP: clientip.Result{Addr: c.IP}, UserAgent: c.UserAgent, RequestID: c.RequestID}
	}
	return s.otp.StartPair(ctx, req(otp.PurposeEmailCurrent, old), req(otp.PurposeEmailNew, next), func(ctx context.Context, tx pgx.Tx, expires time.Time) (otp.PairBinding, error) {
		q := sqlc.New(tx)
		if _, err := q.LockPendingEmailChange(ctx, p.UserID); err != nil {
			return otp.PairBinding{}, err
		} // L2b
		cur, ok, err := accounts.LockForNoKeyUpdate(ctx, tx, p.UserID)
		if err != nil {
			return otp.PairBinding{}, err
		}
		if !ok || !accounts.InGoodStanding(cur) {
			return otp.PairBinding{}, session.ErrUnauthorized
		}
		if cur.EmailRevision != u.EmailRevision || cur.EmailNormalized != old.Normalized {
			return otp.PairBinding{}, session.ErrUnauthorized
		}
		if _, ok, err := session.LockActing(ctx, tx, p.UserID, p.SessionID); err != nil {
			return otp.PairBinding{}, err
		} else if !ok {
			return otp.PairBinding{}, session.ErrUnauthorized
		}
		_, occupied, err := accounts.Find(ctx, tx, next)
		if err != nil {
			return otp.PairBinding{}, err
		}
		if err := q.ClosePendingEmailChanges(ctx, p.UserID); err != nil {
			return otp.PairBinding{}, err
		}
		if err := q.InsertEmailChange(ctx, sqlc.InsertEmailChangeParams{ID: id, UserID: p.UserID, SessionID: p.SessionID, SourceEmailNormalized: old.Normalized, SourceRevision: cur.EmailRevision, NewEmail: next.Display, NewEmailNormalized: next.Normalized, ExpiresAt: expires}); err != nil {
			return otp.PairBinding{}, err
		}
		if err := audit.Record(ctx, tx, event(p, c, "account.email.change.start", map[string]string{"change_id": id.String()})); err != nil {
			return otp.PairBinding{}, err
		}
		return otp.PairBinding{ChangeID: id, UserID: p.UserID, SessionID: p.SessionID, EmailRevision: cur.EmailRevision, NewEligible: !occupied}, nil
	})
}

type ProofPair struct{ CurrentToken, CurrentCode, NewToken, NewCode string }

func (s *Service) CompleteEmailChange(ctx context.Context, p session.Principal, id uuid.UUID, proof ProofPair, c session.Client) error {
	if _, err := sqlc.New(s.pool).GetOwnedEmailChange(ctx, sqlc.GetOwnedEmailChangeParams{ID: id, UserID: p.UserID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrChangeNotFound
		}
		return err
	}
	req := func(purpose otp.Purpose, tok, code string) otp.VerifyRequest {
		return otp.VerifyRequest{Purpose: purpose, Token: tok, Code: code, UserID: &p.UserID, SessionID: &p.SessionID, IP: clientip.Result{Addr: c.IP}, UserAgent: c.UserAgent, RequestID: c.RequestID}
	}
	var revoked int64
	err := s.otp.VerifyPair(ctx, id, [2]otp.VerifyRequest{req(otp.PurposeEmailCurrent, proof.CurrentToken, proof.CurrentCode), req(otp.PurposeEmailNew, proof.NewToken, proof.NewCode)}, func(ctx context.Context, tx pgx.Tx, a otp.Accepted) error {
		revoked = 0
		q := sqlc.New(tx)
		change, err := q.LockEmailChange(ctx, sqlc.LockEmailChangeParams{ID: id, UserID: p.UserID})
		if err != nil {
			return err
		}
		now, err := q.DatabaseNow(ctx)
		if err != nil {
			return err
		}
		if change.ClosedAt != nil || !change.ExpiresAt.After(now) || change.SessionID != p.SessionID {
			return otp.Rollback("change_invalid", otp.ErrInvalidCode)
		}
		u, ok, err := accounts.LockForEmailChange(ctx, tx, p.UserID)
		if err != nil {
			return err
		}
		if !ok || !accounts.InGoodStanding(u) {
			return otp.Rollback("account_unavailable", session.ErrUnauthorized)
		}
		if change.SourceRevision != u.EmailRevision || change.SourceEmailNormalized != u.EmailNormalized || a.EmailRevision != u.EmailRevision || a.Email.Normalized != change.NewEmailNormalized {
			return otp.Rollback("email_changed", otp.ErrInvalidCode)
		}
		if _, ok, err := session.LockActing(ctx, tx, p.UserID, p.SessionID); err != nil {
			return err
		} else if !ok {
			return otp.Rollback("session_invalid", session.ErrUnauthorized)
		}
		if err := accounts.ChangeEmail(ctx, tx, p.UserID, identity.Email{Display: change.NewEmail, Normalized: change.NewEmailNormalized}); err != nil {
			var pgerr *pgconn.PgError
			if errors.As(err, &pgerr) && pgerr.Code == "23505" && pgerr.ConstraintName == "users_email_normalized_key" {
				return otp.Rollback("email_unavailable", ErrEmailUnavailable)
			}
			return err
		}
		reason := "email_change"
		revoked, err = q.RevokeAllSessionsForUser(ctx, sqlc.RevokeAllSessionsForUserParams{UserID: p.UserID, Reason: &reason})
		if err != nil {
			return err
		}
		if err := q.CloseEmailChange(ctx, sqlc.CloseEmailChangeParams{ID: id, UserID: p.UserID}); err != nil {
			return err
		}
		for _, mail := range []struct {
			to       string
			template notify.Template
		}{{u.Email, notify.TemplateEmailChangedOld}, {change.NewEmail, notify.TemplateEmailChangedNew}} {
			if _, err := s.outbox.Enqueue(ctx, tx, notify.Message{To: mail.to, UserID: &p.UserID, Template: mail.template, Payload: notify.Payload{DeviceName: "Account email change", OccurredAt: now}}); err != nil {
				return err
			}
		}
		if err := audit.Record(ctx, tx, event(p, c, "auth.session.revoke", map[string]string{"reason": reason, "count": fmt.Sprint(revoked)})); err != nil {
			return err
		}
		return audit.Record(ctx, tx, event(p, c, "account.email.change.complete", map[string]string{"change_id": id.String(), "revoked_sessions": fmt.Sprint(revoked)}))
	})
	if err == nil {
		s.metrics.SessionsRevoked("email_change", revoked)
	}
	return err
}
