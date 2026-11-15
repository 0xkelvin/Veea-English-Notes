package pgtest

import "testing"

func TestRequireLocal(t *testing.T) {
	ok := []string{
		"postgres://u@localhost:5432/db",
		"postgres://u:p@127.0.0.1:54329/postgres",
		"postgres://u@[::1]:5432/db",
		"postgres:///db",
		"postgres:///db?host=/tmp",
	}
	bad := []string{
		"postgres://u:p@db.example.com:5432/db",
		"postgres://u:p@10.0.0.5/db",
		"postgres://u:p@203.0.113.9/db",
		"postgres:///db?host=db.internal",
	}
	for _, u := range ok {
		if err := RequireLocal(u); err != nil {
			t.Errorf("%s: unexpected error %v", u, err)
		}
	}
	for _, u := range bad {
		if err := RequireLocal(u); err == nil {
			t.Errorf("%s: expected refusal", u)
		}
	}
}
