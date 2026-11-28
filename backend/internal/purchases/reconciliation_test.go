package purchases

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/appleiap"
)

func TestReconciliationGateBoundsInFlightAndBackoff(t *testing.T) {
	var gate reconciliationGate
	now := time.Now()
	for range maxReconciliationInFlight {
		if probe, ok := gate.acquire(now); probe || !ok {
			t.Fatal("healthy reconciliation was refused")
		}
	}
	if _, ok := gate.acquire(now); ok {
		t.Fatal("admitted more than the concurrency limit")
	}
	gate.done(now, false, false, appleiap.ErrUnavailable)
	for range maxReconciliationInFlight - 1 {
		gate.done(now, false, false, nil)
	}
	for _, delay := range []time.Duration{5, 10, 20, 40, 60, 60} {
		next := now.Add(delay * time.Second)
		if _, ok := gate.acquire(next.Add(-time.Nanosecond)); ok {
			t.Fatal("cooldown expired early")
		}
		if probe, ok := gate.acquire(next); !probe || !ok {
			t.Fatal("cooldown failed to admit a recovery probe")
		}
		if _, ok := gate.acquire(next); ok {
			t.Fatal("admitted two recovery probes")
		}
		gate.done(next, true, false, appleiap.ErrUnavailable)
		now = next
	}
	now = now.Add(time.Minute)
	if _, ok := gate.acquire(now); !ok {
		t.Fatal("no recovery probe")
	}
	gate.done(now, true, true, context.Canceled)
	if _, ok := gate.acquire(now); !ok {
		t.Fatal("request cancellation penalized the next recovery probe")
	}
	gate.done(now, true, false, appleiap.ErrInvalid)
	if probe, ok := gate.acquire(now); probe || !ok {
		t.Fatal("a definitive Apple response did not close the cooldown")
	}
	gate.done(now, false, false, nil)
}

type verifierFunc func(context.Context, string) (appleiap.Transaction, error)

func (f verifierFunc) Verify(ctx context.Context, id string) (appleiap.Transaction, error) {
	return f(ctx, id)
}

func TestReconciliationCancellationLeavesGateHealthy(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	s := Service{verifier: verifierFunc(func(verifyCtx context.Context, _ string) (appleiap.Transaction, error) {
		if _, ok := verifyCtx.Deadline(); !ok {
			t.Fatal("no separate deadline for Apple I/O")
		}
		cancel()
		return appleiap.Transaction{}, appleiap.ErrUnavailable
	})}
	if _, err := s.verify(ctx, "123", true); !errors.Is(err, context.Canceled) {
		t.Fatalf("expected request cancellation, got %v", err)
	}
	if probe, ok := s.reconciliation.acquire(time.Now()); probe || !ok {
		t.Fatal("canceled request opened the cooldown")
	}
	s.reconciliation.done(time.Now(), false, false, nil)
}

func TestAppleDeadlineWithLiveRequestIsUpstreamUnavailable(t *testing.T) {
	for _, reconcile := range []bool{false, true} {
		s := Service{verifier: verifierFunc(func(context.Context, string) (appleiap.Transaction, error) {
			return appleiap.Transaction{}, context.DeadlineExceeded
		})}
		if _, err := s.verify(context.Background(), "123", reconcile); !errors.Is(err, appleiap.ErrUnavailable) {
			t.Fatalf("reconcile=%t: expected upstream unavailability, got %v", reconcile, err)
		}
	}
}

func TestReconciliationVerifierPanicReleasesSlot(t *testing.T) {
	for _, recovery := range []bool{false, true} {
		s := Service{verifier: verifierFunc(func(context.Context, string) (appleiap.Transaction, error) {
			panic("synthetic verifier panic")
		})}
		if recovery {
			past := time.Now().Add(-time.Minute)
			probe, ok := s.reconciliation.acquire(past)
			if !ok || probe {
				t.Fatal("could not seed outage")
			}
			s.reconciliation.done(past, probe, false, appleiap.ErrUnavailable)
		}
		func() {
			defer func() {
				if recover() != "synthetic verifier panic" {
					t.Error("expected the verifier panic to propagate")
				}
			}()
			_, _ = s.verify(context.Background(), "123", true)
		}()
		if s.reconciliation.inFlight != 0 {
			t.Fatal("panicking verifier leaked a reconciliation slot")
		}
		if probe, ok := s.reconciliation.acquire(time.Now()); !ok || probe != recovery {
			t.Fatalf("panic changed the gate state: recovery=%t, probe=%t, allowed=%t", recovery, probe, ok)
		}
		s.reconciliation.done(time.Now(), recovery, false, nil)
	}
}
