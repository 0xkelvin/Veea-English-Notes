package db

import (
	"errors"
	"fmt"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

func TestOnlyDeadlocksAndSerializationFailuresAreRetried(t *testing.T) {
	cases := map[string]struct {
		err  error
		want bool
	}{
		"deadlock":          {&pgconn.PgError{Code: SQLStateDeadlock}, true},
		"serialization":     {&pgconn.PgError{Code: SQLStateSerialization}, true},
		"wrapped deadlock":  {fmt.Errorf("otp: lock: %w", &pgconn.PgError{Code: SQLStateDeadlock}), true},
		"unique violation":  {&pgconn.PgError{Code: "23505"}, false},
		"check violation":   {&pgconn.PgError{Code: "23514"}, false},
		"application error": {errors.New("invalid_code"), false},
		"no error":          {nil, false},
	}
	for name, c := range cases {
		if _, got := retryableState(c.err); got != c.want {
			t.Errorf("%s: retryable = %v, want %v", name, got, c.want)
		}
	}
}
