// Package migrations embeds the SQL migrations applied by cmd/migrate.
package migrations

import "embed"

// FS holds every migration file. The pattern also matches README.md and this file, so it
// compiles before the first .sql file exists; goose ignores non-SQL files.
//
//go:embed *
var FS embed.FS
