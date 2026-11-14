package notify

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"mime"
	"mime/quotedprintable"
	"net"
	"net/mail"
	"net/smtp"
	"net/textproto"
	"strings"
	"time"
)

// SMTPSender delivers through a plain SMTP server without authentication or TLS. It exists for
// local development against Mailpit (TRD 2.3) and is restricted to loopback addresses, so OTP
// codes never cross a network in clear text. The production provider is still open (TRD R12).
type SMTPSender struct {
	addr string // host:port
	from string
	// helo is the name announced in EHLO.
	helo string
}

// NewSMTPSender returns a sender for addr ("127.0.0.1:1025") with envelope and header sender
// from. addr must be a loopback address or "localhost".
func NewSMTPSender(addr, from string) (*SMTPSender, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil || port == "" {
		return nil, errors.New("notify: SMTP address must be host:port")
	}
	if !isLoopbackHost(host) {
		return nil, errors.New("notify: the SMTP sender is for local Mailpit only and accepts loopback hosts only")
	}
	parsed, err := mail.ParseAddress(from)
	if err != nil || parsed.Name != "" || parsed.Address != from {
		return nil, errors.New("notify: sender address must be a bare email address")
	}
	return &SMTPSender{addr: addr, from: from, helo: "localhost"}, nil
}

func isLoopbackHost(h string) bool {
	if h == "localhost" {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

// Send implements Sender. Failures are classified per TRD 8.3:
//   - before the end of DATA the server has not accepted anything, so connection errors and 4xx
//     replies are Retryable and 5xx replies are Permanent;
//   - after the final "." is written, a missing or unreadable reply is Ambiguous: the server may
//     have queued the message.
func (s *SMTPSender) Send(ctx context.Context, e Email) (string, error) {
	if err := validAddress(e.To); err != nil {
		return "", Permanent("invalid_recipient")
	}
	msgID := fmt.Sprintf("<%s@veea.local>", e.ID)
	body, err := buildMIME(s.from, e, msgID)
	if err != nil {
		return "", Permanent("build_message")
	}

	var d net.Dialer
	conn, err := d.DialContext(ctx, "tcp", s.addr)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return "", Retryable("connect_timeout")
		}
		return "", Retryable("connect")
	}
	defer conn.Close()
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	}

	host, _, _ := net.SplitHostPort(s.addr)
	c, err := smtp.NewClient(conn, host)
	if err != nil {
		return "", beforeAcceptance(err, "greeting")
	}
	if err := c.Hello(s.helo); err != nil {
		return "", beforeAcceptance(err, "helo")
	}
	if err := c.Mail(s.from); err != nil {
		return "", beforeAcceptance(err, "mail")
	}
	if err := c.Rcpt(e.To); err != nil {
		return "", beforeAcceptance(err, "rcpt")
	}
	w, err := c.Data()
	if err != nil {
		return "", beforeAcceptance(err, "data")
	}
	if _, err := w.Write(body); err != nil {
		return "", beforeAcceptance(err, "write")
	}
	if err := w.Close(); err != nil {
		var tp *textproto.Error
		if errors.As(err, &tp) {
			// The server answered the end of DATA with a definite refusal.
			return "", replyError(tp, "data_end")
		}
		// No usable reply after the message was fully written: it may be queued.
		return "", Ambiguous("data_end_no_reply")
	}
	_ = c.Quit()
	return msgID, nil
}

// beforeAcceptance classifies a failure that happened before the server could have accepted
// the message.
func beforeAcceptance(err error, stage string) error {
	var tp *textproto.Error
	if errors.As(err, &tp) {
		return replyError(tp, stage)
	}
	return Retryable(stage + "_io")
}

func replyError(tp *textproto.Error, stage string) error {
	code := fmt.Sprintf("smtp_%s_%d", stage, tp.Code)
	if tp.Code >= 500 {
		return Permanent(code)
	}
	return Retryable(code)
}

// buildMIME renders a multipart/alternative message with quoted-printable text and HTML parts.
// Header values are checked for CR and LF so nothing can be injected.
func buildMIME(from string, e Email, msgID string) ([]byte, error) {
	for _, h := range []string{from, e.To, e.Subject} {
		if strings.ContainsAny(h, "\r\n") {
			return nil, errors.New("header value contains a line break")
		}
	}
	var rb [12]byte
	if _, err := rand.Read(rb[:]); err != nil {
		return nil, err
	}
	boundary := "veea-" + hex.EncodeToString(rb[:])

	var b bytes.Buffer
	header := func(k, v string) { b.WriteString(k + ": " + v + "\r\n") }
	header("From", from)
	header("To", e.To)
	header("Subject", mime.QEncoding.Encode("utf-8", e.Subject))
	header("Date", time.Now().UTC().Format(time.RFC1123Z))
	header("Message-ID", msgID)
	header("MIME-Version", "1.0")
	header("Content-Type", `multipart/alternative; boundary="`+boundary+`"`)
	b.WriteString("\r\n")

	part := func(contentType, body string) error {
		b.WriteString("--" + boundary + "\r\n")
		b.WriteString("Content-Type: " + contentType + "; charset=utf-8\r\n")
		b.WriteString("Content-Transfer-Encoding: quoted-printable\r\n\r\n")
		qp := quotedprintable.NewWriter(&b)
		if _, err := qp.Write([]byte(strings.ReplaceAll(body, "\n", "\r\n"))); err != nil {
			return err
		}
		if err := qp.Close(); err != nil {
			return err
		}
		b.WriteString("\r\n")
		return nil
	}
	if err := part("text/plain", e.Text); err != nil {
		return nil, err
	}
	if err := part("text/html", e.HTML); err != nil {
		return nil, err
	}
	b.WriteString("--" + boundary + "--\r\n")
	return b.Bytes(), nil
}
