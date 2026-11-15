// Command admin holds operator-only account administration (TRD 06 §4.3). Today it has one
// subcommand, bootstrap-super-admin, which promotes an existing active, verified account. It
// never runs on API startup, never creates accounts, never sets passwords and never prints an
// email address. Break-glass recovery exists only here, never in the HTTP API.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/admin"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity"
)

const usage = `usage: admin bootstrap-super-admin (--user-id UUID | --email ADDRESS)
             [--mode first|break_glass] [--reason-code CODE] [--ticket-ref REF]
  (reads VEEA_DATABASE_URL)
  first        (default) only when no active Super Admin exists
  break_glass  recovery when every Super Admin is unreachable; needs --reason-code
               lost_access, account_compromise or other
`

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	os.Exit(run(ctx, os.Args[1:], os.Getenv, os.Stdout, os.Stderr))
}

// bootstrapper is admin.Bootstrap; replaced in unit tests so parsing needs no database.
var bootstrapper = func(ctx context.Context, url string, req admin.BootstrapRequest) (admin.BootstrapResult, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return admin.BootstrapResult{}, err
	}
	defer pool.Close()
	return admin.Bootstrap(ctx, pool, req)
}

func run(ctx context.Context, args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	req, code := parse(args, stderr)
	if code != 0 {
		return code
	}
	url := getenv("VEEA_DATABASE_URL")
	if url == "" {
		fmt.Fprintln(stderr, "VEEA_DATABASE_URL is required")
		return 2
	}
	res, err := bootstrapper(ctx, url, req)
	switch {
	case errors.Is(err, admin.ErrAlreadyProvisioned):
		fmt.Fprintln(stderr, "refused: an active Super Admin already exists; use the API, or --mode break_glass for recovery")
		return 1
	case errors.Is(err, admin.ErrIneligibleTarget):
		fmt.Fprintln(stderr, "refused: the account must exist, be active and verified, and not already be a Super Admin")
		return 1
	case errors.Is(err, admin.ErrInvalidBootstrap):
		fmt.Fprint(stderr, "refused: invalid mode, reason code or ticket reference\n"+usage)
		return 2
	case err != nil:
		fmt.Fprintln(stderr, "error: bootstrap failed") // no detail: it could quote input
		return 1
	}
	fmt.Fprintf(stdout, "user_id=%s role=super_admin role_revision=%d revoked_sessions=%d mode=%s\n",
		res.UserID, res.RoleRevision, res.RevokedSessions, req.Mode)
	return 0
}

func parse(args []string, stderr io.Writer) (admin.BootstrapRequest, int) {
	var req admin.BootstrapRequest
	if len(args) == 0 || args[0] != "bootstrap-super-admin" {
		fmt.Fprint(stderr, usage)
		return req, 2
	}
	fs := flag.NewFlagSet("bootstrap-super-admin", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	userID := fs.String("user-id", "", "")
	email := fs.String("email", "", "")
	mode := fs.String("mode", admin.ModeFirst, "")
	reason := fs.String("reason-code", "", "")
	ticket := fs.String("ticket-ref", "", "")
	if err := fs.Parse(args[1:]); err != nil || fs.NArg() != 0 || (*userID == "") == (*email == "") {
		fmt.Fprint(stderr, usage)
		return req, 2
	}
	if *userID != "" {
		id, err := uuid.Parse(*userID)
		if err != nil || id == uuid.Nil {
			fmt.Fprint(stderr, "invalid --user-id\n"+usage)
			return req, 2
		}
		req.UserID = &id
	} else {
		e, err := identity.NormalizeEmail(*email)
		if err != nil {
			fmt.Fprint(stderr, "invalid --email\n"+usage)
			return req, 2
		}
		req.Email = &e
	}
	req.Mode, req.ReasonCode = *mode, *reason
	if *ticket != "" {
		req.TicketRef = ticket
	}
	return req, 0
}
