package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"time"

	"github.com/0xkelvin/Veea-English-Notes/backend/internal/recoveryledger"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

const ledgerUsage = `usage: admin ledger archive --store DIR --source UUID [--initialize]
       admin ledger recover --store DIR --source UUID --backup-at RFC3339 --required-through RFC3339 --min-generation N --out FILE
       admin ledger status --store DIR --source UUID --backup-at RFC3339 --required-through RFC3339 --min-generation N
  dedicated VEEA_RECOVERY_KEYS=id:64hex[,previous...] is required for all operations
  only archive reads VEEA_DATABASE_URL; recover/status never connect to the source DB
`

func ledgerCommand(ctx context.Context, args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, ledgerUsage)
		return 2
	}
	action := args[0]
	if action != "archive" && action != "recover" && action != "status" {
		fmt.Fprint(stderr, ledgerUsage)
		return 2
	}
	fs := flag.NewFlagSet("ledger", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	dir := fs.String("store", "", "")
	src := fs.String("source", "", "")
	backup := fs.String("backup-at", "", "")
	through := fs.String("required-through", "", "")
	generation := fs.Int64("min-generation", 0, "")
	out := fs.String("out", "", "")
	initialize := fs.Bool("initialize", false, "")
	if fs.Parse(args[1:]) != nil || fs.NArg() != 0 {
		fmt.Fprint(stderr, ledgerUsage)
		return 2
	}
	source, err := uuid.Parse(*src)
	if err != nil || source == uuid.Nil || *dir == "" {
		fmt.Fprint(stderr, ledgerUsage)
		return 2
	}
	var req recoveryledger.Requirement
	if action != "archive" {
		if *initialize {
			fmt.Fprint(stderr, ledgerUsage)
			return 2
		}
		at, e1 := time.Parse(time.RFC3339Nano, *backup)
		cutoff, e2 := time.Parse(time.RFC3339Nano, *through)
		if e1 != nil || e2 != nil || *generation < 1 || at.After(cutoff) || (action == "recover" && *out == "") || (action == "status" && *out != "") {
			fmt.Fprint(stderr, ledgerUsage)
			return 2
		}
		req = recoveryledger.Requirement{Source: source, BackupAt: at, RequiredThrough: cutoff, MinGeneration: *generation}
	} else if *backup != "" || *through != "" || *out != "" || *generation != 0 {
		fmt.Fprint(stderr, ledgerUsage)
		return 2
	}
	keys, err := recoveryledger.ParseKeys(getenv("VEEA_RECOVERY_KEYS"))
	if err != nil {
		fmt.Fprintln(stderr, "dedicated VEEA_RECOVERY_KEYS is missing or invalid")
		return 2
	}
	store, err := recoveryledger.NewFileStore(*dir, source, keys)
	if err != nil {
		fmt.Fprintln(stderr, "refused: private independent recovery store unavailable")
		return 1
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	var receipt recoveryledger.Receipt
	if action == "archive" {
		url := getenv("VEEA_DATABASE_URL")
		if url == "" {
			fmt.Fprintln(stderr, "VEEA_DATABASE_URL is required for archive only")
			return 2
		}
		pool, e := pgxpool.New(ctx, url)
		if e != nil {
			fmt.Fprintln(stderr, "refused: source database unavailable")
			return 1
		}
		defer pool.Close()
		receipt, err = recoveryledger.Archive(ctx, pool, store, source, *initialize)
	} else {
		var checkpoint recoveryledger.Checkpoint
		checkpoint, receipt, err = recoveryledger.Recover(ctx, store, req)
		if err == nil && action == "recover" {
			var raw []byte
			raw, err = recoveryledger.RestoreSQL(checkpoint, receipt, req)
			if err == nil {
				err = recoveryledger.WriteRestoreFile(*out, raw)
			}
		}
	}
	if err != nil {
		switch {
		case errors.Is(err, recoveryledger.ErrBehind):
			fmt.Fprintln(stderr, "blocked: checkpoint behind required recovery boundary; keep access and sync closed")
		case errors.Is(err, recoveryledger.ErrGap):
			fmt.Fprintln(stderr, "blocked: source rewind or ledger gap; keep access and sync closed")
		case errors.Is(err, recoveryledger.ErrMissing):
			fmt.Fprintln(stderr, "blocked: independent checkpoint missing; keep access and sync closed")
		default:
			fmt.Fprintln(stderr, "blocked: checkpoint could not be published or verified; keep access and sync closed")
		}
		return 1
	}
	if json.NewEncoder(stdout).Encode(receipt) != nil {
		return 1
	}
	return 0
}
