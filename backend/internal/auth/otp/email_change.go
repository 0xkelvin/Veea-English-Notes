package otp

import (
	"bytes"
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

type PairAcknowledgement struct {
	ChangeID     uuid.UUID
	Current, New Acknowledgement
}

// PairBinding is returned only after the flow has locked its request, user and acting session.
// NewEligible=false keeps the proposed proof inert and unmailed while retaining its caller binding.
type PairBinding struct {
	ChangeID, UserID, SessionID uuid.UUID
	EmailRevision               int64
	LifecycleRevision           int64
	NewEligible                 bool
}

type PreparePair func(context.Context, pgx.Tx, time.Time) (PairBinding, error)

// StartPair owns all challenge writes, delaying new FK inserts until after L3/L4 checks.
func (s *Service) StartPair(ctx context.Context, current, proposed StartRequest, prepare PreparePair) (PairAcknowledgement, error) {
	if current.Purpose != PurposeEmailCurrent || proposed.Purpose != PurposeEmailNew || prepare == nil {
		return PairAcknowledgement{}, errors.New("otp: invalid proof pair")
	}
	reqs := [2]StartRequest{current, proposed}
	var plans [2]startPlan
	for i, req := range reqs {
		if req.Email.Normalized == "" {
			return PairAcknowledgement{}, errors.New("otp: pair needs normalized addresses")
		}
		if err := s.checkStartLimits(ctx, req); err != nil {
			return PairAcknowledgement{}, err
		}
		p, err := s.newStartPlan(purposes[req.Purpose], req)
		if err != nil {
			return PairAcknowledgement{}, err
		}
		plans[i] = p
	}
	for plans[1].code == plans[0].code {
		code, err := newCode(s.random)
		if err != nil {
			return PairAcknowledgement{}, err
		}
		plans[1].code = code
	}
	var out PairAcknowledgement
	err := s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		out = PairAcknowledgement{}
		if err := LockAddresses(ctx, tx, current.Email.Normalized, proposed.Email.Normalized); err != nil {
			return err
		}
		for _, p := range plans { // fixed current/new purpose order, L1 only
			claim, err := s.cooldown.Claim(ctx, tx, string(p.req.Purpose), p.req.Email)
			if err != nil {
				return err
			}
			if !claim.Granted {
				return s.cooldownError(p.req.Purpose, p.req.Email, claim.RetryAfterSeconds())
			}
		}
		now, err := sqlc.New(tx).DatabaseNow(ctx)
		if err != nil {
			return err
		}
		expires := now.Add(Lifetime)
		binding, err := prepare(ctx, tx, expires)
		if err != nil {
			return err
		}
		out.ChangeID = binding.ChangeID
		for i, p := range plans {
			t := Target{Eligible: i == 0 || binding.NewEligible, UserID: &binding.UserID,
				SessionID: &binding.SessionID, EmailRevision: binding.EmailRevision, LifecycleRevision: binding.LifecycleRevision, To: p.req.Email.Display}
			if err := sqlc.New(tx).InsertEmailChangeChallenge(ctx, sqlc.InsertEmailChangeChallengeParams{
				ID: p.id, TokenHash: p.tokenHash, Purpose: string(p.req.Purpose), Email: p.req.Email.Display, EmailNormalized: p.req.Email.Normalized,
				UserID: t.UserID, SessionID: t.SessionID, CodeHash: s.codes.Hash(p.id, p.code), Delivery: delivery(t),
				MaxAttempts: MaxAttempts, ExpiresAt: expires, RequestIp: addrPtr(p.req.IP.Addr), EmailRevision: t.EmailRevision, LifecycleRevision: t.LifecycleRevision, ChangeID: &binding.ChangeID,
			}); err != nil {
				return err
			}
			if err := s.queueEmails(ctx, tx, p, t, nil, expires); err != nil {
				return err
			}
			if err := s.recordStart(ctx, tx, p, t); err != nil {
				return err
			}
			ack := Acknowledgement{ChallengeToken: p.token, ExpiresAt: expires, ResendAfter: now.Add(time.Duration(s.cooldownSeconds()) * time.Second), delivery: delivery(t)}
			if i == 0 {
				out.Current = ack
			} else {
				out.New = ack
			}
		}
		return nil
	})
	if err == nil {
		s.metrics.OTPStarted(string(PurposeEmailCurrent), out.Current.delivery)
		s.metrics.OTPStarted(string(PurposeEmailNew), out.New.delivery)
	}
	return out, err
}

// VerifyPair atomically consumes both valid proofs with the callback. Failed comparisons
// commit only the failing proof's attempt and audit; no valid proof is consumed on rejection.
func (s *Service) VerifyPair(ctx context.Context, changeID uuid.UUID, reqs [2]VerifyRequest, then AfterAccept) error {
	if reqs[0].Purpose != PurposeEmailCurrent || reqs[1].Purpose != PurposeEmailNew || then == nil {
		return errors.New("otp: invalid proof pair")
	}
	for _, r := range reqs {
		if r.UserID == nil || r.SessionID == nil {
			return errors.New("otp: pair requires caller")
		}
		if err := s.checkVerifyLimits(ctx, r, HashToken(r.Token)); err != nil {
			return err
		}
	}
	if *reqs[0].UserID != *reqs[1].UserID || *reqs[0].SessionID != *reqs[1].SessionID {
		return errors.New("otp: mismatched pair caller")
	}
	var outcomes [2]outcome
	var completed bool
	err := s.tx.Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		outcomes = [2]outcome{}
		completed = false
		q := sqlc.New(tx)
		hashes := [][]byte{HashToken(reqs[0].Token), HashToken(reqs[1].Token)}
		rows, err := q.LockOTPProofPair(ctx, hashes)
		if err != nil {
			return err
		}
		now, err := q.WallClock(ctx)
		if err != nil {
			return err
		}
		var selected [2]sqlc.OtpChallenge
		var invalid [2]error
		for i, r := range reqs {
			found := false
			for _, ch := range rows {
				if bytes.Equal(ch.TokenHash, hashes[i]) {
					selected[i] = ch
					found = true
					break
				}
			}
			ch := selected[i]
			if found {
				email := identity.Email{Display: ch.Email, Normalized: ch.EmailNormalized}
				outcomes[i].email = &email
				outcomes[i].hmac = s.emailHMAC.Current(email)
				outcomes[i].target = ch.UserID
			}
			if !found || ch.ChangeID == nil || *ch.ChangeID != changeID || bytes.Equal(hashes[0], hashes[1]) {
				invalid[i] = ErrInvalidCode
			} else {
				invalid[i] = unusable(purposes[r.Purpose], ch, r, now)
			}
		}
		for i, reason := range invalid {
			if reason != nil {
				return s.reject(ctx, tx, purposes[reqs[i].Purpose], reqs[i], &outcomes[i], reason, false)
			}
		}
		bad := false
		for i, r := range reqs {
			ch := selected[i]
			if !s.codes.Match(ch.ID, r.Code, ch.CodeHash) || ch.Delivery != "code" {
				bad = true
				if err := updateLocked(q.IncrementOTPChallengeAttempts(ctx, ch.ID)); err != nil {
					return err
				}
				if err := s.reject(ctx, tx, purposes[r.Purpose], r, &outcomes[i], ErrInvalidCode, true); err != nil {
					return err
				}
			}
		}
		if bad {
			return nil
		}
		for _, ch := range selected {
			if err := updateLocked(q.ConsumeOTPChallenge(ctx, ch.ID)); err != nil {
				return err
			}
		}
		if err := s.runFlow(ctx, tx, purposes[reqs[1].Purpose], reqs[1], accepted(selected[1], reqs[1], &outcomes[1]), then, &outcomes[1]); err != nil {
			return err
		}
		_, err = q.CancelPendingOutboxForChallenge(ctx, &selected[0].ID)
		completed = err == nil
		return err
	})
	if err != nil {
		return s.settle(ctx, purposes[reqs[1].Purpose], reqs[1], &outcomes[1], err)
	}
	var result error
	for i, r := range reqs {
		if !completed && outcomes[i].reject == nil {
			continue
		}
		e := s.settle(ctx, purposes[r.Purpose], r, &outcomes[i], err)
		if e != nil {
			result = e
		}
	}
	return result
}

// MatchesAccount must be checked under the flow's L3 user lock after single-code acceptance.
func MatchesAccount(a Accepted, u sqlc.User) bool {
	return a.EmailRevision == u.EmailRevision && a.LifecycleRevision == u.LifecycleRevision && a.Email.Normalized == u.EmailNormalized
}
