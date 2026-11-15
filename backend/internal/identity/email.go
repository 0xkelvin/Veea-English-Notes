package identity

import (
	"errors"
	"net/mail"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

// MaxEmailOctets is the longest normalized email accepted (TRD 3.2 rule 5).
const MaxEmailOctets = 254

// maxEmailInputBytes bounds the work done on hostile input before parsing.
const maxEmailInputBytes = 1024

// ErrInvalidEmail is returned for every email that fails validation. The reason is
// deliberately not exposed: the API maps it to a single invalid_email error.
var ErrInvalidEmail = errors.New("identity: invalid email")

// Email is a validated address in both of its forms.
type Email struct {
	// Display is the address as the user typed it, trimmed. It is shown back to the user
	// and stored in users.email.
	Display string
	// Normalized is the canonical form used for every lookup and stored in
	// users.email_normalized. Two spellings of one mailbox share it (AC-8).
	Normalized string
}

// LocalPart returns the part of Normalized before the final "@".
func (e Email) LocalPart() string {
	if i := strings.LastIndexByte(e.Normalized, '@'); i >= 0 {
		return e.Normalized[:i]
	}
	return e.Normalized
}

// NormalizeEmail validates input and returns its display and normalized forms.
//
// Rules, in order (TRD 3.2):
//  1. Trim surrounding whitespace.
//  2. Parse with net/mail.ParseAddress and require the parsed address to equal the input
//     exactly, with no display name. That rejects "Name <a@b.test>", "<a@b.test>",
//     quoted local parts, comments and address lists.
//  3. Apply Unicode NFC, then lowercase the whole address.
//  4. At most 254 octets after normalization, and the normalized form must still parse as the
//     same address (rule 2 applied again).
//  5. Dots and "+tag" suffixes are kept: stripping them is provider specific and would
//     merge distinct mailboxes.
//
// Beyond the TRD, control characters and invalid UTF-8 are rejected. A NUL byte cannot be
// stored in a PostgreSQL text column, and the rest has no legitimate use in an address.
//
// The result is kept in NFC after lowercasing, so NormalizeEmail(x.Normalized) always returns
// x.Normalized (idempotence), even for letters whose lowercase form needs recomposition.
func NormalizeEmail(input string) (Email, error) {
	trimmed := strings.TrimSpace(input)
	if trimmed == "" || len(trimmed) > maxEmailInputBytes || !utf8.ValidString(trimmed) {
		return Email{}, ErrInvalidEmail
	}
	for _, r := range trimmed {
		if unicode.IsControl(r) {
			return Email{}, ErrInvalidEmail
		}
	}

	addr, err := mail.ParseAddress(trimmed)
	if err != nil || addr.Name != "" || addr.Address != trimmed {
		return Email{}, ErrInvalidEmail
	}

	normalized := norm.NFC.String(strings.ToLower(norm.NFC.String(trimmed)))
	if len(normalized) > MaxEmailOctets {
		return Email{}, ErrInvalidEmail
	}
	// Normalization can change validity: U+037E (Greek question mark) is accepted by the parser
	// but its NFC form is ";", which is not. The stored value must itself be a valid address,
	// so parse it again.
	if again, err := mail.ParseAddress(normalized); err != nil || again.Name != "" || again.Address != normalized {
		return Email{}, ErrInvalidEmail
	}
	return Email{Display: trimmed, Normalized: normalized}, nil
}
