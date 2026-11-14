package notify

import (
	"bufio"
	"context"
	"errors"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

// scriptedSMTP is a tiny SMTP server whose replies the test chooses. It records the DATA it
// receives.
type scriptedSMTP struct {
	ln       net.Listener
	mu       sync.Mutex
	data     strings.Builder
	rcptCode string // reply to RCPT, default "250 ok"
	endCode  string // reply to the end of DATA, default "250 queued"
	dropEnd  bool   // close the connection instead of answering the end of DATA
}

func newScriptedSMTP(t *testing.T) *scriptedSMTP {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := &scriptedSMTP{ln: ln}
	t.Cleanup(func() { ln.Close() })
	go s.serve()
	return s
}

func (s *scriptedSMTP) addr() string { return s.ln.Addr().String() }

func (s *scriptedSMTP) serve() {
	for {
		conn, err := s.ln.Accept()
		if err != nil {
			return
		}
		go s.handle(conn)
	}
}

func (s *scriptedSMTP) handle(conn net.Conn) {
	defer conn.Close()
	r := bufio.NewReader(conn)
	write := func(line string) { conn.Write([]byte(line + "\r\n")) }
	write("220 scripted ESMTP")
	inData := false
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		if inData {
			if line == ".\r\n" {
				inData = false
				s.mu.Lock()
				drop, code := s.dropEnd, s.endCode
				s.mu.Unlock()
				if drop {
					return
				}
				if code == "" {
					code = "250 queued"
				}
				write(code)
				continue
			}
			s.mu.Lock()
			s.data.WriteString(line)
			s.mu.Unlock()
			continue
		}
		cmd := strings.ToUpper(strings.TrimSpace(line))
		switch {
		case strings.HasPrefix(cmd, "EHLO"), strings.HasPrefix(cmd, "HELO"):
			write("250 scripted")
		case strings.HasPrefix(cmd, "MAIL FROM"):
			write("250 ok")
		case strings.HasPrefix(cmd, "RCPT TO"):
			s.mu.Lock()
			code := s.rcptCode
			s.mu.Unlock()
			if code == "" {
				code = "250 ok"
			}
			write(code)
		case cmd == "DATA":
			write("354 go ahead")
			inData = true
		case cmd == "QUIT":
			write("221 bye")
			return
		default:
			write("502 unknown")
		}
	}
}

func testEmail() Email {
	return Email{ID: uuid.New(), To: "learner@example.test", Subject: "Your Veea sign-in code",
		Text: "Your code: 123456\n.\nend", HTML: "<p>123456</p>"}
}

func classOf(t *testing.T, err error) (Class, string) {
	t.Helper()
	var se *SendError
	if !errors.As(err, &se) {
		t.Fatalf("expected a classified SendError, got %v", err)
	}
	return se.Class, se.Code
}

func TestSMTPSenderDelivers(t *testing.T) {
	srv := newScriptedSMTP(t)
	s, err := NewSMTPSender(srv.addr(), "no-reply@veea.local")
	if err != nil {
		t.Fatal(err)
	}
	e := testEmail()
	id, err := s.Send(context.Background(), e)
	if err != nil {
		t.Fatal(err)
	}
	if id != "<"+e.ID.String()+"@veea.local>" {
		t.Fatalf("provider id should be the Message-ID built from the outbox id, got %s", id)
	}
	srv.mu.Lock()
	data := srv.data.String()
	srv.mu.Unlock()
	for _, want := range []string{"Message-ID: <" + e.ID.String() + "@veea.local>", "To: learner@example.test",
		"multipart/alternative", "text/plain", "text/html", "123456"} {
		if !strings.Contains(data, want) {
			t.Errorf("message lacks %q", want)
		}
	}
	// A lone "." line in the body was dot-stuffed and did not end the message early.
	if !strings.Contains(data, "end") {
		t.Error("the body was cut at a dot line")
	}
}

func TestSMTPSenderClassifiesFailures(t *testing.T) {
	cases := []struct {
		name  string
		setup func(*scriptedSMTP)
		class Class
		code  string
	}{
		{"recipient rejected permanently", func(s *scriptedSMTP) { s.rcptCode = "550 no such user" }, ClassPermanent, "smtp_rcpt_550"},
		{"recipient deferred", func(s *scriptedSMTP) { s.rcptCode = "451 try later" }, ClassRetryable, "smtp_rcpt_451"},
		{"message rejected at end of data", func(s *scriptedSMTP) { s.endCode = "554 content rejected" }, ClassPermanent, "smtp_data_end_554"},
		{"message deferred at end of data", func(s *scriptedSMTP) { s.endCode = "452 mailbox full" }, ClassRetryable, "smtp_data_end_452"},
		// The whole message was written, then the connection died: the server may have queued it.
		{"no reply after data", func(s *scriptedSMTP) { s.dropEnd = true }, ClassAmbiguous, "data_end_no_reply"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			srv := newScriptedSMTP(t)
			c.setup(srv)
			s, _ := NewSMTPSender(srv.addr(), "no-reply@veea.local")
			_, err := s.Send(context.Background(), testEmail())
			class, code := classOf(t, err)
			if class != c.class || code != c.code {
				t.Fatalf("got %s/%s, want %s/%s", class, code, c.class, c.code)
			}
			if strings.Contains(err.Error(), "123456") {
				t.Fatal("error contains the message body")
			}
		})
	}
}

func TestSMTPSenderConnectionRefusedIsRetryable(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := ln.Addr().String()
	ln.Close() // nothing listens any more
	s, _ := NewSMTPSender(addr, "no-reply@veea.local")
	_, err := s.Send(context.Background(), testEmail())
	if class, _ := classOf(t, err); class != ClassRetryable {
		t.Fatalf("connection refused before sending is a definite non-delivery, got %s", class)
	}
}

func TestSMTPSenderHonorsTheDeadline(t *testing.T) {
	// A server that accepts and never speaks.
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			defer c.Close()
		}
	}()
	s, _ := NewSMTPSender(ln.Addr().String(), "no-reply@veea.local")
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := s.Send(ctx, testEmail())
	if err == nil || time.Since(start) > 3*time.Second {
		t.Fatalf("send did not stop at the deadline: %v after %s", err, time.Since(start))
	}
	// Silence before the greeting is before any acceptance: retryable.
	if class, _ := classOf(t, err); class != ClassRetryable {
		t.Fatalf("got %s", class)
	}
}

func TestSMTPSenderSafety(t *testing.T) {
	for _, addr := range []string{"smtp.example.com:25", "10.0.0.5:25", "203.0.113.1:587", "localhost"} {
		if _, err := NewSMTPSender(addr, "no-reply@veea.local"); err == nil {
			t.Errorf("%s: only loopback hosts with a port are allowed", addr)
		}
	}
	for _, from := range []string{"Veea <no-reply@veea.local>", "not-an-address", "a@b.test\r\nBcc: x@y.test"} {
		if _, err := NewSMTPSender("127.0.0.1:1025", from); err == nil {
			t.Errorf("%q: bad sender accepted", from)
		}
	}
	s, _ := NewSMTPSender("127.0.0.1:1", "no-reply@veea.local")
	e := testEmail()
	e.To = "a@b.test\r\nBcc: x@y.test"
	if _, err := s.Send(context.Background(), e); err == nil {
		t.Fatal("a recipient with a line break must be refused")
	} else if class, _ := classOf(t, err); class != ClassPermanent {
		t.Fatalf("got %s", class)
	}
	e = testEmail()
	e.Subject = "hi\r\nBcc: x@y.test"
	if _, err := buildMIME("no-reply@veea.local", e, "<x@y>"); err == nil {
		t.Fatal("a subject with a line break must be refused")
	}
}
