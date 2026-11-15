package migrate

import (
	"errors"

	"github.com/jackc/pgx/v5"
)

// pgxParse hides the URL from error text, since pgx errors may quote it.
func pgxParse(databaseURL string) (*pgx.ConnConfig, error) {
	cfg, err := pgx.ParseConfig(databaseURL)
	if err != nil {
		return nil, errors.New("migrate: invalid database URL")
	}
	return cfg, nil
}
