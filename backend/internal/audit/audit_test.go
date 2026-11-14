package audit

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// noDB fails the test if Record reaches the database: every case below must be refused first.
type noDB struct{ t *testing.T }

func (d noDB) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	d.t.Fatal("refused events must not reach the database")
	return pgconn.CommandTag{}, nil
}
func (d noDB) Query(context.Context, string, ...any) (pgx.Rows, error) {
	d.t.Fatal("refused events must not reach the database")
	return nil, nil
}
func (d noDB) QueryRow(context.Context, string, ...any) pgx.Row {
	d.t.Fatal("refused events must not reach the database")
	return nil
}

func TestRecordRefusesSecretsAndMalformedEvents(t *testing.T) {
	ok := Event{Action: "auth.otp.verify", Outcome: Failure, Reason: "invalid_code"}
	cases := map[string]func(e *Event){
		"empty action":        func(e *Event) { e.Action = "" },
		"action with spaces":  func(e *Event) { e.Action = "auth otp" },
		"unknown outcome":     func(e *Event) { e.Outcome = "maybe" },
		"free text reason":    func(e *Event) { e.Reason = "wrong code 123456" },
		"code key":            func(e *Event) { e.Metadata = map[string]string{"code": "123456"} },
		"token key":           func(e *Event) { e.Metadata = map[string]string{"challenge_token": "x"} },
		"password key":        func(e *Event) { e.Metadata = map[string]string{"new_password": "x"} },
		"hash key":            func(e *Event) { e.Metadata = map[string]string{"code_hash": "x"} },
		"challenge token":     func(e *Event) { e.Metadata = map[string]string{"note": "vct_abc"} },
		"access token":        func(e *Event) { e.Metadata = map[string]string{"note": "Bearer vat_abc"} },
		"token in user agent": func(e *Event) { e.UserAgent = "client vrt_abc" },
		"uppercase key":       func(e *Event) { e.Metadata = map[string]string{"Delivery": "none"} },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			e := ok
			mutate(&e)
			if err := Record(context.Background(), noDB{t}, e); err == nil {
				t.Fatal("expected the event to be refused")
			}
		})
	}
	e := ok
	e.Metadata = map[string]string{"code": "1"}
	if err := Record(context.Background(), noDB{t}, e); !errors.Is(err, ErrUnsafeEvent) {
		t.Fatalf("a secret must be reported as ErrUnsafeEvent, got %v", err)
	}
}
