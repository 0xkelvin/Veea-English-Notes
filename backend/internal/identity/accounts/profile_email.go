package accounts

import (
	"context"
	"errors"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// LockForEmailChange is the TRD 03 L3 exception for updating the unique email key.
func LockForEmailChange(ctx context.Context, tx pgx.Tx, id uuid.UUID) (sqlc.User, bool, error) {
	u, err := sqlc.New(tx).LockUserForEmailChange(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return sqlc.User{}, false, nil
	}
	return u, err == nil, err
}

func UpdateProfile(ctx context.Context, tx pgx.Tx, p sqlc.UpdateProfileParams) (sqlc.User, error) {
	return sqlc.New(tx).UpdateProfile(ctx, p)
}

func ChangeEmail(ctx context.Context, tx pgx.Tx, id uuid.UUID, e identity.Email) error {
	n, err := sqlc.New(tx).ChangeVerifiedEmail(ctx, sqlc.ChangeVerifiedEmailParams{ID: id, Email: e.Display, EmailNormalized: e.Normalized})
	if err != nil {
		return err
	}
	if n != 1 {
		return errors.New("accounts: locked email owner not updated")
	}
	return nil
}
