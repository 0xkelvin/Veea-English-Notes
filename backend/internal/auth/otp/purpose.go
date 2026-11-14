package otp

import (
	"errors"
	"fmt"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/notify"
)

// Purpose is what a challenge is for (TRD 4.3), matching the otp_challenges.purpose CHECK.
type Purpose string

const (
	PurposeSignup        Purpose = "signup"
	PurposeLogin         Purpose = "login"
	PurposePasswordReset Purpose = "password_reset"
	PurposeSetPassword   Purpose = "set_password"
)

// SignupMethod distinguishes the two signup paths (TRD 4.3). Only signup challenges have one.
type SignupMethod string

const (
	SignupOTP      SignupMethod = "otp"
	SignupPassword SignupMethod = "password"
)

type purposeInfo struct {
	template     notify.Template
	startAction  string
	verifyAction string
	// needsUser: an eligible challenge is bound to an existing account.
	needsUser bool
	// callerBound: the challenge is bound to the caller's user and session, and verification
	// must present the same pair (TRD 4.3, 7.3 step 2).
	callerBound bool
}

// purposes maps each purpose to its email template and audit actions (TRD 11.1).
var purposes = map[Purpose]purposeInfo{
	PurposeSignup: {template: notify.TemplateSignupCode,
		startAction: "auth.signup.start", verifyAction: "auth.signup.verify"},
	PurposeLogin: {template: notify.TemplateLoginCode, needsUser: true,
		startAction: "auth.otp.start", verifyAction: "auth.otp.verify"},
	PurposePasswordReset: {template: notify.TemplateResetCode, needsUser: true,
		startAction: "auth.password.reset.start", verifyAction: "auth.password.reset.complete"},
	PurposeSetPassword: {template: notify.TemplateSetPasswordCode, needsUser: true, callerBound: true,
		startAction: "auth.password.set.start", verifyAction: "auth.password.set"},
}

func (p Purpose) info() (purposeInfo, error) {
	i, ok := purposes[p]
	if !ok {
		return purposeInfo{}, fmt.Errorf("otp: unknown purpose %q", string(p))
	}
	return i, nil
}

// Rejections returned by Verify. Both are public error codes (TRD 5.3) and say nothing about
// why: an unknown token, a wrong code, an expired, consumed or superseded challenge, a wrong
// purpose or binding and a delivery = 'none' challenge all give ErrInvalidCode.
var (
	ErrInvalidCode      = errors.New("invalid_code")
	ErrAttemptsExceeded = errors.New("code_attempts_exceeded")
)

// RateLimitedError is a 429 (TRD 10). RetryAfter is the Retry-After value in whole seconds,
// at least 1. Rule names the limit, for logs and the auth.rate_limited audit event.
type RateLimitedError struct {
	Rule       string
	RetryAfter int
}

func (e *RateLimitedError) Error() string {
	return fmt.Sprintf("rate_limited: %s, retry after %ds", e.Rule, e.RetryAfter)
}

// Audit reasons written by this package (TRD 11.1).
const (
	ReasonInvalidCode      = "invalid_code"
	ReasonAttemptsExceeded = "attempts_exceeded"
)

// Flow outcomes. An AfterAccept callback returns one of these to end the transaction in a way
// other than a plain commit (nil) or a plain rollback (any other error).

// flowFailure is returned by an AfterAccept callback through CommitFailure or Rollback.
type flowFailure struct {
	commit bool
	reason string
	err    error
}

func (f *flowFailure) Error() string { return f.err.Error() }
func (f *flowFailure) Unwrap() error { return f.err }

// CommitFailure ends a redemption whose flow cannot finish but whose consumption must stand:
// the challenge stays consumed, its pending email is cancelled, a failure audit event with
// reason is written, everything commits, and Verify returns err. Signup verify uses it when the
// account appeared in the meantime (TRD 7.3, 409 signup_unavailable).
func CommitFailure(reason string, err error) error {
	return &flowFailure{commit: true, reason: reason, err: err}
}

// Rollback ends a redemption by rolling back everything, the consumption included, so the code
// can be used again once the cause is fixed (TRD 7.5). A failure audit event with reason is then
// written in its own short transaction (T-fail), and Verify returns err. OTP verify uses it when
// the account is no longer active (TRD 7.3).
func Rollback(reason string, err error) error {
	return &flowFailure{reason: reason, err: err}
}
