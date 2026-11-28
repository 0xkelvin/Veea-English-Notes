package purchases

import (
	"context"
	"errors"
	"testing"
	"testing/synctest"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/appleiap"
)

func tryGate(gate *reconciliationGate, now time.Time) (bool, bool) {
	gate.mu.Lock()
	defer gate.mu.Unlock()
	probe, err := gate.tryAcquire(now)
	return probe, err == nil
}

func TestReconciliationGateBoundsInFlightAndBackoff(t *testing.T) {
	var gate reconciliationGate
	now := time.Now()
	for range maxReconciliationInFlight {
		if probe, ok := tryGate(&gate, now); probe || !ok {
			t.Fatal("healthy reconciliation was refused")
		}
	}
	if _, ok := tryGate(&gate, now); ok {
		t.Fatal("admitted more than the concurrency limit")
	}
	gate.done(now, false, false, appleiap.ErrUnavailable)
	for range maxReconciliationInFlight - 1 {
		gate.done(now, false, false, nil)
	}
	for _, delay := range []time.Duration{5, 10, 20, 40, 60, 60} {
		next := now.Add(delay * time.Second)
		if _, ok := tryGate(&gate, next.Add(-time.Nanosecond)); ok {
			t.Fatal("cooldown expired early")
		}
		if probe, ok := tryGate(&gate, next); !probe || !ok {
			t.Fatal("cooldown failed to admit a recovery probe")
		}
		if _, ok := tryGate(&gate, next); ok {
			t.Fatal("admitted two recovery probes")
		}
		gate.done(next, true, false, appleiap.ErrUnavailable)
		now = next
	}
	now = now.Add(time.Minute)
	if _, ok := tryGate(&gate, now); !ok {
		t.Fatal("no recovery probe")
	}
	gate.done(now, true, true, context.Canceled)
	if _, ok := tryGate(&gate, now); !ok {
		t.Fatal("request cancellation penalized the next recovery probe")
	}
	gate.done(now, true, false, appleiap.ErrInvalid)
	if probe, ok := tryGate(&gate, now); probe || !ok {
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
	if probe, ok := tryGate(&s.reconciliation, time.Now()); probe || !ok {
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

func TestReconciliationKeepsSuccessfulRefundAtAppleDeadline(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		now := time.Now()
		refund := appleiap.Transaction{ID: "123", RevokedAt: &now}
		s := Service{verifier: verifierFunc(func(ctx context.Context, _ string) (appleiap.Transaction, error) {
			<-ctx.Done()
			return refund, nil
		})}
		s.reconciliation.retryAt = now
		s.reconciliation.backoff = 5 * time.Second
		proof, err := s.verify(context.Background(), refund.ID, true)
		if err != nil || proof.ID != refund.ID || proof.RevokedAt != refund.RevokedAt {
			t.Fatalf("verified refund was lost: %+v, %v", proof, err)
		}
		if s.reconciliation.inFlight != 0 || !s.reconciliation.retryAt.IsZero() {
			t.Fatal("successful recovery did not release its slot and close the circuit")
		}
	})
}

func fillReconciliationGate(t *testing.T, gate *reconciliationGate) {
	t.Helper()
	for range maxReconciliationInFlight {
		if probe, err := gate.acquire(context.Background()); probe || err != nil {
			t.Fatalf("could not fill healthy gate: probe=%t, err=%v", probe, err)
		}
	}
}

func TestReconciliationSlotWaitAndSaturation(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var gate reconciliationGate
		fillReconciliationGate(t, &gate)
		results := make(chan error, maxReconciliationWaiters)
		for range maxReconciliationWaiters {
			go func() {
				_, err := gate.acquire(context.Background())
				results <- err
			}()
		}
		synctest.Wait()
		start := time.Now()
		if _, err := gate.acquire(context.Background()); err != ErrReconcileSaturated || !time.Now().Equal(start) {
			t.Fatalf("full waiter queue did not immediately report saturation: %v", err)
		}
		time.Sleep(100 * time.Millisecond)
		gate.done(time.Now(), false, false, nil)
		if err := <-results; err != nil || gate.inFlight != maxReconciliationInFlight {
			t.Fatalf("released slot was not handed to a waiter: %v", err)
		}
		for range maxReconciliationWaiters - 1 {
			if err := <-results; err != ErrReconcileSaturated {
				t.Fatalf("expected bounded wait to report saturation, got %v", err)
			}
		}
		if time.Since(start) != 250*time.Millisecond || gate.waiters != 0 || !gate.retryAt.IsZero() {
			t.Fatal("saturation exceeded its wait budget, leaked a waiter, or opened the circuit")
		}
		for range maxReconciliationInFlight {
			gate.done(time.Now(), false, false, nil)
		}
		if gate.inFlight != 0 || gate.changed != nil {
			t.Fatal("gate did not release all resources")
		}
	})
}

func TestReconciliationSlotWaitRespectsCancellationAndCooldown(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var gate reconciliationGate
		fillReconciliationGate(t, &gate)
		result := make(chan error)
		wait := func(ctx context.Context) {
			_, err := gate.acquire(ctx)
			result <- err
		}
		ctx, cancel := context.WithCancel(context.Background())
		go wait(ctx)
		synctest.Wait()
		cancel()
		if err := <-result; err != context.Canceled || gate.waiters != 0 {
			t.Fatalf("waiter did not release on cancellation: %v", err)
		}
		ctx, cancel = context.WithTimeout(context.Background(), 25*time.Millisecond)
		defer cancel()
		go wait(ctx)
		if err := <-result; err != context.DeadlineExceeded || gate.waiters != 0 {
			t.Fatalf("waiter did not release on deadline: %v", err)
		}
		go wait(context.Background())
		synctest.Wait()
		start := time.Now()
		gate.done(start, false, false, appleiap.ErrUnavailable)
		if err := <-result; err != ErrReconcileBackoff || !time.Now().Equal(start) {
			t.Fatalf("queued request waited through cooldown: %v", err)
		}
		if _, err := gate.acquire(context.Background()); err != ErrReconcileBackoff || !time.Now().Equal(start) {
			t.Fatalf("new request waited through cooldown: %v", err)
		}
	})
}

func TestExplicitVerificationBypassesSaturatedReconciliation(t *testing.T) {
	s := Service{verifier: verifierFunc(func(_ context.Context, id string) (appleiap.Transaction, error) {
		return appleiap.Transaction{ID: id}, nil
	})}
	fillReconciliationGate(t, &s.reconciliation)
	if proof, err := s.verify(context.Background(), "123", false); err != nil || proof.ID != "123" {
		t.Fatalf("explicit verification waited for reconciliation: %+v, %v", proof, err)
	}
}

func TestReconciliationVerifierPanicReleasesSlot(t *testing.T) {
	for _, recovery := range []bool{false, true} {
		s := Service{verifier: verifierFunc(func(context.Context, string) (appleiap.Transaction, error) {
			panic("synthetic verifier panic")
		})}
		if recovery {
			past := time.Now().Add(-time.Minute)
			probe, ok := tryGate(&s.reconciliation, past)
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
		if probe, ok := tryGate(&s.reconciliation, time.Now()); !ok || probe != recovery {
			t.Fatalf("panic changed the gate state: recovery=%t, probe=%t, allowed=%t", recovery, probe, ok)
		}
		s.reconciliation.done(time.Now(), recovery, false, nil)
	}
}
