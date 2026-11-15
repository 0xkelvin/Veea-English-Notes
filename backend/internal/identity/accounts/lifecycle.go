package accounts

import (
	"context"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func SetState(ctx context.Context, tx pgx.Tx, id uuid.UUID, status string) error {
	return sqlc.New(tx).SetAccountState(ctx, sqlc.SetAccountStateParams{ID: id, Status: status})
}
func Erase(ctx context.Context, tx pgx.Tx, id uuid.UUID) (int64, error) {
	return sqlc.New(tx).DeleteAccount(ctx, id)
}
