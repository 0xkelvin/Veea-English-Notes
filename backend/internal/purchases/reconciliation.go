package purchases

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/appleiap"
)

var (
	ErrReconcileBackoff   = fmt.Errorf("%w: reconciliation cooling down", appleiap.ErrUnavailable)
	ErrReconcileSaturated = fmt.Errorf("%w: no reconciliation slot available", appleiap.ErrUnavailable)
)

const (
	maxReconciliationInFlight = 4
	maxReconciliationWaiters  = 4
	reconciliationSlotWait    = 250 * time.Millisecond
)

// reconciliationGate bounds background reads on each API replica. It never
// holds a mutex across I/O and stores no account or transaction identifiers.
type reconciliationGate struct {
	mu       sync.Mutex
	inFlight int
	waiters  int
	changed  chan struct{}
	retryAt  time.Time
	backoff  time.Duration
}

func (g *reconciliationGate) acquire(ctx context.Context) (bool, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return false, err
	}
	probe, err := g.tryAcquire(time.Now())
	if err != ErrReconcileSaturated || g.waiters >= maxReconciliationWaiters {
		return probe, err
	}

	deadline := time.Now().Add(reconciliationSlotWait)
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	g.waiters++
	defer func() { g.waiters-- }()
	for {
		if g.changed == nil {
			g.changed = make(chan struct{})
		}
		changed := g.changed
		g.mu.Unlock()
		select {
		case <-ctx.Done():
		case <-timer.C:
		case <-changed:
		}
		g.mu.Lock()
		if err := ctx.Err(); err != nil {
			return false, err
		}
		if !time.Now().Before(deadline) {
			return false, ErrReconcileSaturated
		}
		probe, err := g.tryAcquire(time.Now())
		if err != ErrReconcileSaturated {
			return probe, err
		}
	}
}

// tryAcquire runs with mu held.
func (g *reconciliationGate) tryAcquire(now time.Time) (probe bool, err error) {
	probe = !g.retryAt.IsZero()
	if probe && (now.Before(g.retryAt) || g.inFlight != 0) {
		return false, ErrReconcileBackoff
	}
	if g.inFlight >= maxReconciliationInFlight {
		return false, ErrReconcileSaturated
	}
	g.inFlight++
	return probe, nil
}

func (g *reconciliationGate) done(now time.Time, probe, canceled bool, err error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.inFlight--
	if g.changed != nil {
		close(g.changed)
		g.changed = nil
	}
	if canceled {
		return
	}
	if errors.Is(err, appleiap.ErrUnavailable) {
		if probe || g.retryAt.IsZero() {
			g.backoff = min(max(5*time.Second, g.backoff*2), time.Minute)
			g.retryAt = now.Add(g.backoff)
		}
	} else if probe {
		g.retryAt = time.Time{}
		g.backoff = 0
	}
}
