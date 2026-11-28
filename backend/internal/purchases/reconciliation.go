package purchases

import (
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/appleiap"
)

var ErrReconcileBackoff = fmt.Errorf("%w: reconciliation cooling down or busy", appleiap.ErrUnavailable)

const maxReconciliationInFlight = 4

// reconciliationGate bounds background reads on each API replica. It never
// holds a mutex across I/O and stores no account or transaction identifiers.
type reconciliationGate struct {
	mu       sync.Mutex
	inFlight int
	retryAt  time.Time
	backoff  time.Duration
}

func (g *reconciliationGate) acquire(now time.Time) (probe, allowed bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	probe = !g.retryAt.IsZero()
	if g.inFlight >= maxReconciliationInFlight || (probe && (now.Before(g.retryAt) || g.inFlight != 0)) {
		return false, false
	}
	g.inFlight++
	return probe, true
}

func (g *reconciliationGate) done(now time.Time, probe, canceled bool, err error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.inFlight--
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
