package notify

import (
	"context"
	"sync"
)

// FakeSender records every email instead of delivering it. It is the sender for tests
// (VEEA_EMAIL_SENDER=fake). Respond, when set, decides each call's outcome, and may block to
// simulate a slow provider. Calls are recorded before Respond runs, so an email the fake "lost"
// after acceptance still shows up, which is how tests observe duplicate delivery.
type FakeSender struct {
	mu      sync.Mutex
	sent    []Email
	Respond func(ctx context.Context, e Email, call int) (string, error)
}

// Send implements Sender.
func (f *FakeSender) Send(ctx context.Context, e Email) (string, error) {
	f.mu.Lock()
	f.sent = append(f.sent, e)
	call := len(f.sent)
	respond := f.Respond
	f.mu.Unlock()
	if respond != nil {
		return respond(ctx, e, call)
	}
	return "fake-" + e.ID.String(), nil
}

// Sent returns a copy of every email received, in call order.
func (f *FakeSender) Sent() []Email {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Email(nil), f.sent...)
}

// Calls is the number of Send calls so far.
func (f *FakeSender) Calls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.sent)
}
