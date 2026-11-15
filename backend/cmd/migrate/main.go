// Command migrate applies database migrations and exits. It is a separate
// binary so a deploy can migrate before new API instances start (TRD 01 R9).
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/migrate"
	"github.com/0xkelvin/Veea-English-Notes/backend/migrations"
)

const usage = "usage: migrate [up|status]   (reads VEEA_DATABASE_URL)\n"

func main() { os.Exit(run(os.Args[1:])) }

func run(args []string) int {
	cmd := "up"
	if len(args) > 0 {
		cmd = args[0]
	}
	if cmd != "up" && cmd != "status" || len(args) > 1 {
		fmt.Fprint(os.Stderr, usage)
		return 2
	}
	url := os.Getenv("VEEA_DATABASE_URL")
	if url == "" {
		fmt.Fprintln(os.Stderr, "VEEA_DATABASE_URL is required")
		return 2
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var (
		res migrate.Result
		err error
	)
	if cmd == "up" {
		res, err = migrate.Up(ctx, url, migrations.FS)
	} else {
		res, err = migrate.Status(ctx, url, migrations.FS)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		return 1
	}
	if cmd == "up" {
		fmt.Printf("applied=%d current_version=%d\n", len(res.Applied), res.Current)
	} else {
		fmt.Printf("current_version=%d pending=%d\n", res.Current, res.Pending)
	}
	return 0
}
