package notify

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
)

// Outbox writes email rows. It has no connection of its own: every call runs on the caller's
// transaction, so an email exists exactly when the state change that caused it commits
// (TRD 7.1 rule 2, lock level L5).
type Outbox struct {
	keys *Keyring
}

// NewOutbox returns an Outbox sealing payloads with keys.
func NewOutbox(keys *Keyring) *Outbox { return &Outbox{keys: keys} }

// Enqueue validates msg, encrypts its payload for the new row and inserts it on tx. It
// returns the row id. Nothing is sent here: the worker delivers after commit.
func (o *Outbox) Enqueue(ctx context.Context, tx pgx.Tx, msg Message) (uuid.UUID, error) {
	if err := msg.validate(); err != nil {
		return uuid.Nil, err
	}
	id, err := uuid.NewV7()
	if err != nil {
		return uuid.Nil, errors.New("notify: generate outbox id")
	}
	plain, err := encodePayload(msg.Payload)
	if err != nil {
		return uuid.Nil, err
	}
	sealed, keyID, err := o.keys.Seal(id, plain)
	clear(plain)
	if err != nil {
		return uuid.Nil, err
	}
	_, err = sqlc.New(tx).InsertOutboxEmail(ctx, sqlc.InsertOutboxEmailParams{
		ID: id, UserID: msg.UserID, ChallengeID: msg.ChallengeID, ToEmail: msg.To,
		Template: string(msg.Template), PayloadCiphertext: sealed, PayloadKeyID: &keyID, NotAfter: msg.NotAfter,
	})
	if err != nil {
		return uuid.Nil, fmt.Errorf("notify: insert outbox row: %w", err)
	}
	return id, nil
}

// CancelForChallenge cancels and scrubs the pending email of a challenge that was consumed or
// superseded, on the caller's transaction (TRD 8.2). It returns the number of rows cancelled.
// It also clears the lease, so a worker that is sending right now cannot record its result.
func (o *Outbox) CancelForChallenge(ctx context.Context, tx pgx.Tx, challengeID uuid.UUID) (int64, error) {
	n, err := sqlc.New(tx).CancelPendingOutboxForChallenge(ctx, &challengeID)
	if err != nil {
		return 0, fmt.Errorf("notify: cancel outbox rows: %w", err)
	}
	return n, nil
}
