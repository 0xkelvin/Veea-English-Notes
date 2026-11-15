package main

import (
	"context"
	"flag"
	"fmt"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/admin"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/learning"
	"github.com/jackc/pgx/v5/pgxpool"
	"io"
	"os"
)

func publishCartridge(ctx context.Context, args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("publish-cartridge", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := fs.String("file", "", "")
	ticket := fs.String("ticket-ref", "", "")
	if fs.Parse(args) != nil || fs.NArg() != 0 || *file == "" || !admin.ValidTicketRef(*ticket) || *ticket == "" {
		fmt.Fprintln(stderr, "usage: admin publish-cartridge --file FILE --ticket-ref REF")
		return 2
	}
	f, err := os.Open(*file)
	if err != nil {
		fmt.Fprintln(stderr, "error: cannot read cartridge")
		return 2
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, learning.MaxCartridgeBytes+1))
	if err != nil || len(raw) > learning.MaxCartridgeBytes {
		fmt.Fprintln(stderr, "error: cartridge exceeds size limit or cannot be read")
		return 2
	}
	url := getenv("VEEA_DATABASE_URL")
	if url == "" {
		fmt.Fprintln(stderr, "VEEA_DATABASE_URL is required")
		return 2
	}
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		fmt.Fprintln(stderr, "error: cannot connect")
		return 1
	}
	defer pool.Close()
	changed, err := learning.PublishCartridge(ctx, pool, raw, *ticket)
	if err != nil {
		fmt.Fprintln(stderr, "refused: invalid, conflicting or unavailable cartridge publication")
		return 1
	}
	fmt.Fprintf(stdout, "cartridge_published=%t\n", changed)
	return 0
}
