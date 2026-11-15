package identity

import (
	"errors"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

// Policy limits (TRD 9.1, decision R8).
const (
	MinPasswordLength = 15
	MaxPasswordLength = 128

	// minEmailLocalPartForCheck is the shortest local part the contains_email rule uses.
	minEmailLocalPartForCheck = 3

	// MaxPasswordInputBytes bounds the raw input examined before normalization. 128 code
	// points need at most 512 bytes, so a longer input is treated as too long without being
	// normalized. That is a deliberate approximation: only absurd inputs, such as thousands of
	// combining marks that would compose into few characters, differ from the exact answer. It
	// keeps hostile input away from the NFKC pass and from Argon2.
	MaxPasswordInputBytes = 4096
)

// Violation is a stable machine-readable policy failure code (TRD 9.1).
type Violation string

const (
	TooShort      Violation = "too_short"
	TooLong       Violation = "too_long"
	TooCommon     Violation = "too_common"
	ContainsEmail Violation = "contains_email"
)

// ErrInvalidPasswordEncoding means the password is not valid UTF-8. JSON decoding normally
// prevents this, so handlers map it to a plain bad-request error, not to a violation.
var ErrInvalidPasswordEncoding = errors.New("identity: password is not valid UTF-8")

// PolicyError reports every violated rule at once, in a fixed order.
type PolicyError struct {
	Violations []Violation
}

func (e *PolicyError) Error() string {
	parts := make([]string, len(e.Violations))
	for i, v := range e.Violations {
		parts[i] = string(v)
	}
	return "identity: password policy violation: " + strings.Join(parts, ", ")
}

// Policy checks passwords against the Phase 1 rules. It is safe for concurrent use.
type Policy struct {
	blocklist *Blocklist
}

// NewPolicy returns a policy using blocklist. A nil blocklist disables the too_common rule,
// which is only meant for tests.
func NewPolicy(blocklist *Blocklist) *Policy { return &Policy{blocklist: blocklist} }

// NormalizePassword applies the Unicode NFKC form the TRD requires before every check and
// before hashing. Spaces are significant and nothing is trimmed.
func NormalizePassword(password string) string { return norm.NFKC.String(password) }

// Validate checks password against the policy. email is the account's normalized email
// (Email.Normalized) and may be empty when the account is not known yet.
//
// On success it returns the NFKC-normalized password, the form to pass to the Hasher. On
// failure it returns a *PolicyError listing all violations in this order: too_short or
// too_long, too_common, contains_email. Hashers normalize again, which is idempotent.
//
// Length counts code points of the normalized password.
func (p *Policy) Validate(password, email string) (string, error) {
	if !utf8.ValidString(password) {
		return "", ErrInvalidPasswordEncoding
	}
	if len(password) > MaxPasswordInputBytes {
		return "", &PolicyError{Violations: []Violation{TooLong}}
	}

	normalized := NormalizePassword(password)
	var violations []Violation

	switch n := utf8.RuneCountInString(normalized); {
	case n < MinPasswordLength:
		violations = append(violations, TooShort)
	case n > MaxPasswordLength:
		violations = append(violations, TooLong)
	}

	lowered := strings.ToLower(normalized)
	if p.blocklist != nil && p.blocklist.Contains(normalized) {
		violations = append(violations, TooCommon)
	}
	if local := emailLocalPart(email); utf8.RuneCountInString(local) >= minEmailLocalPartForCheck &&
		strings.Contains(lowered, local) {
		violations = append(violations, ContainsEmail)
	}

	if len(violations) > 0 {
		return "", &PolicyError{Violations: violations}
	}
	return normalized, nil
}

// emailLocalPart returns the comparison form of the local part of a normalized email.
func emailLocalPart(email string) string {
	if email == "" {
		return ""
	}
	local := email
	if i := strings.LastIndexByte(email, '@'); i >= 0 {
		local = email[:i]
	}
	return normalizeForCompare(local)
}
