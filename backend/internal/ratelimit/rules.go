// Package ratelimit implements the PostgreSQL fixed-window rate limiter and the OTP resend
// cooldown of TRD 01 section 10.
//
// Two properties shape the design:
//
//   - Counters never share a transaction with the caller. The Limiter takes a *pgxpool.Pool and
//     runs every statement in autocommit, so a business transaction that fails and rolls back
//     cannot undo the record of the attempt (TRD 7.1 rules 3 and 6).
//   - The cooldown does the opposite. Claim takes a pgx.Tx, so the claim commits or rolls back
//     together with the challenge it allows (TRD 7.2 step 1).
//
// Everything is measured on database time, so all API instances agree on window boundaries.
package ratelimit

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

// Rule is one limit: at most Limit events per fixed Window for one subject.
//
// Windows are aligned to the Unix epoch, so a one-hour rule resets at the top of every hour
// (UTC) and a 24-hour rule at 00:00 UTC. A fixed window can admit up to twice Limit across a
// boundary. That is the accepted trade-off of this design.
type Rule struct {
	// Name identifies the rule inside counter keys, for example "otp_start_email_1h". It must
	// be lowercase letters, digits and underscores.
	Name   string
	Limit  int
	Window time.Duration
}

// Validate checks that the rule can be used.
func (r Rule) Validate() error {
	if r.Name == "" || strings.Trim(r.Name, "abcdefghijklmnopqrstuvwxyz0123456789_") != "" {
		return fmt.Errorf("ratelimit: rule name %q must be lowercase letters, digits and underscores", r.Name)
	}
	if r.Limit < 1 {
		return fmt.Errorf("ratelimit: rule %s: limit must be at least 1", r.Name)
	}
	if r.Window < time.Second || r.Window%time.Second != 0 {
		return fmt.Errorf("ratelimit: rule %s: window must be a whole number of seconds", r.Name)
	}
	return nil
}

// CooldownSeconds is the OTP resend cooldown per purpose and email (TRD 4.2, 7.2).
const CooldownSeconds = 60

// Rules is the full rule set of TRD 10. The numbers are the approved defaults. Callers may
// build their own Rules value to change any of them. TestDefaultRulesMatchTheTRD pins these.
type Rules struct {
	// Start (every OTP start, whatever the purpose).
	StartEmailHourly Rule
	StartEmailDaily  Rule
	StartIP          Rule
	// Verify failures, counted only for failed verifications.
	VerifyFailEmail Rule
	VerifyIP        Rule
	// Password login.
	PasswordLoginFailEmail Rule
	PasswordLoginIP        Rule
	// Password signup start, limited per IP because it costs an Argon2 run.
	PasswordSignupStartIP Rule
	// Change password with a wrong current password.
	WrongCurrentPasswordUser Rule
	// Authenticated traffic.
	RefreshSession Rule
	RequestSession Rule
}

// DefaultRules returns the TRD 10 table.
func DefaultRules() Rules {
	return Rules{
		StartEmailHourly:         Rule{Name: "otp_start_email_1h", Limit: 5, Window: time.Hour},
		StartEmailDaily:          Rule{Name: "otp_start_email_24h", Limit: 10, Window: 24 * time.Hour},
		StartIP:                  Rule{Name: "otp_start_ip_1h", Limit: 30, Window: time.Hour},
		VerifyFailEmail:          Rule{Name: "otp_verify_fail_email_1h", Limit: 10, Window: time.Hour},
		VerifyIP:                 Rule{Name: "otp_verify_ip_1h", Limit: 60, Window: time.Hour},
		PasswordLoginFailEmail:   Rule{Name: "login_fail_email_15m", Limit: 10, Window: 15 * time.Minute},
		PasswordLoginIP:          Rule{Name: "login_ip_15m", Limit: 50, Window: 15 * time.Minute},
		PasswordSignupStartIP:    Rule{Name: "signup_password_start_ip_1h", Limit: 10, Window: time.Hour},
		WrongCurrentPasswordUser: Rule{Name: "wrong_current_password_user_15m", Limit: 5, Window: 15 * time.Minute},
		RefreshSession:           Rule{Name: "refresh_session_1m", Limit: 30, Window: time.Minute},
		RequestSession:           Rule{Name: "request_session_1m", Limit: 600, Window: time.Minute},
	}
}

// All lists every rule, for validation and tests.
func (r Rules) All() []Rule {
	return []Rule{
		r.StartEmailHourly, r.StartEmailDaily, r.StartIP, r.VerifyFailEmail, r.VerifyIP,
		r.PasswordLoginFailEmail, r.PasswordLoginIP, r.PasswordSignupStartIP,
		r.WrongCurrentPasswordUser, r.RefreshSession, r.RequestSession,
	}
}

// Validate checks every rule and that no two share a name, which would merge their counters.
func (r Rules) Validate() error {
	seen := map[string]bool{}
	var errs []error
	for _, rule := range r.All() {
		if err := rule.Validate(); err != nil {
			errs = append(errs, err)
			continue
		}
		if seen[rule.Name] {
			errs = append(errs, fmt.Errorf("ratelimit: duplicate rule name %s", rule.Name))
		}
		seen[rule.Name] = true
	}
	return errors.Join(errs...)
}
