package lifecycle

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/audit"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/otp"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/auth/session"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/identity/accounts"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db"
	"github.com/0xkelvin/Veea-English-Notes/backend/internal/platform/db/sqlc"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"strconv"
	"time"
)

func formatCount(n int64) string { return strconv.FormatInt(n, 10) }

// RunBatch runs on the cleanup runner's dedicated advisory-lock connection, with each
// checkpoint committed independently. The application handler cannot invoke this worker.
func (s *Service) RunBatch(ctx context.Context, conn *pgxpool.Conn, batch int32) (int64, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	q := sqlc.New(conn)
	ids, err := q.ListAccountJobs(ctx, batch)
	if err != nil {
		return 0, err
	}
	var n int64
	var errs error
	for _, id := range ids {
		job, result, err := s.runJob(ctx, conn, id, batch)
		if err != nil {
			errs = errors.Join(errs, err)
			s.metrics.AccountJob(job, "error")
			continue
		}
		n++
		if result != "" { // counted only after the job transaction committed
			s.metrics.AccountJob(job, result)
		}
	}
	if err := s.expireArtifacts(ctx, conn, batch); err != nil {
		errs = errors.Join(errs, err)
	}
	for _, cleanup := range []func(context.Context, int32) (int64, error){q.ExpirePendingOperationCapabilities, q.CleanupAccountOperations, q.CleanupDeletionLedger, q.CleanupAddressFences, q.CleanupOldAudit} {
		if _, err := cleanup(ctx, batch); err != nil {
			errs = errors.Join(errs, err)
		}
	}
	return n, errs
}

// expireArtifacts discards one bounded batch of ready exports past their 24 h download window,
// with one account.export.expire event per operation in the same transaction.
func (s *Service) expireArtifacts(ctx context.Context, conn *pgxpool.Conn, batch int32) error {
	var expired int
	err := (db.Tx{Pool: conn}).Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := sqlc.New(tx).ExpireAccountArtifacts(ctx, batch)
		if err != nil {
			return err
		}
		expired = len(rows)
		for _, r := range rows {
			if err := audit.Record(ctx, tx, evidence(sessionClient(), r.UserID, "account.export.expire", map[string]string{"operation_id": r.ID.String()})); err != nil {
				return err
			}
		}
		return nil
	})
	if err == nil {
		for range expired {
			s.metrics.AccountJob("export", "expired")
		}
	}
	return err
}

// runJob advances one pending operation by one committed checkpoint. It reports the job kind
// and, when the transaction reached a terminal state, the fixed metric result.
func (s *Service) runJob(ctx context.Context, conn *pgxpool.Conn, id uuid.UUID, batch int32) (job, result string, _ error) {
	before, err := sqlc.New(conn).ReadAccountOperation(ctx, id)
	if err != nil {
		return "unknown", "", err
	}
	job = before.Action
	if before.State != "pending" || before.UserID == nil {
		return job, "", nil
	}
	err = (db.Tx{Pool: conn}).Run(ctx, func(ctx context.Context, tx pgx.Tx) error {
		result = ""
		q := sqlc.New(tx)
		var locked []uuid.UUID
		if before.Action == "delete" {
			u, ok, err := accounts.Get(ctx, tx, *before.UserID)
			if err != nil {
				return err
			}
			if !ok {
				return errors.New("rights: pending purge owner absent")
			}
			if err := otp.LockAddresses(ctx, tx, u.EmailNormalized); err != nil {
				return err
			}
			locked, err = otp.LockOwned(ctx, tx, *before.UserID, batch)
			if err != nil {
				return err
			}
			if before.PurgeStep == 2 {
				if _, err := q.LockAccountEmailChanges(ctx, *before.UserID); err != nil {
					return err
				}
				if _, err := q.LockAccountOperations(ctx, before.UserID); err != nil {
					return err
				}
			}
		}
		var u sqlc.User
		var ok bool
		if before.Action == "delete" && before.PurgeStep == 2 {
			u, ok, err = accounts.LockForEmailChange(ctx, tx, *before.UserID)
		} else {
			u, ok, err = accounts.LockForNoKeyUpdate(ctx, tx, *before.UserID)
		}
		if err != nil {
			return err
		}
		op, err := q.ReadAccountOperation(ctx, id)
		if err != nil {
			return err
		}
		if op.State != "pending" {
			return nil
		}
		if op.Action == "export" {
			if !ok || !eligible("export", u) || u.EmailRevision != op.EmailRevision || u.LifecycleRevision != op.LifecycleRevision {
				n, err := q.CancelAccountOperation(ctx, op.ID)
				if err != nil || n == 0 {
					return err
				}
				result = "canceled"
				return audit.Record(ctx, tx, evidence(sessionClient(), op.UserID, "account.export.cancel", map[string]string{"operation_id": id.String()}))
			}
			// All product data presently lives in one row. No auth, session or audit material.
			payload := struct {
				SchemaVersion int       `json:"schema_version"`
				SnapshotAt    time.Time `json:"snapshot_at"`
				Account       struct {
					ID          uuid.UUID  `json:"user_id"`
					Email       string     `json:"email"`
					VerifiedAt  *time.Time `json:"email_verified_at"`
					CreatedAt   time.Time  `json:"created_at"`
					DisplayName *string    `json:"display_name"`
					Language    string     `json:"preferred_language"`
					TimeZone    string     `json:"time_zone"`
					DailyGoal   int32      `json:"daily_goal"`
				} `json:"account"`
			}{SchemaVersion: 1}
			payload.SnapshotAt, err = q.WallClock(ctx)
			if err != nil {
				return err
			}
			payload.Account.ID = u.ID
			payload.Account.Email = u.Email
			payload.Account.VerifiedAt = u.EmailVerifiedAt
			payload.Account.CreatedAt = u.CreatedAt
			payload.Account.DisplayName = u.DisplayName
			payload.Account.Language = u.PreferredLanguage
			payload.Account.TimeZone = u.TimeZone
			payload.Account.DailyGoal = u.DailyGoal
			plain, err := json.Marshal(payload)
			if err != nil {
				return errors.New("rights: encode export")
			}
			defer clear(plain)
			sealed, key, err := s.keys.Seal(op.ArtifactID, plain)
			if err != nil {
				return err
			}
			if err := q.PublishAccountExport(ctx, sqlc.PublishAccountExportParams{ID: id, ArtifactCiphertext: sealed, ArtifactKeyID: &key}); err != nil {
				return err
			}
			result = "ready"
			return audit.Record(ctx, tx, evidence(sessionClient(), op.UserID, "account.export.ready", map[string]string{"operation_id": id.String()}))
		}
		if !ok || u.Status != "pending_deletion" {
			return errors.New("rights: purge owner not sealed")
		}
		// Lower-level proof locks were acquired before the user. Cascaded outbox writes are L5.
		if len(locked) > 0 {
			_, err := otp.DeleteOwnedLocked(ctx, tx, u.ID, locked)
			return err
		}
		switch op.PurgeStep {
		case 0:
			if err := q.AdvanceAccountPurge(ctx, sqlc.AdvanceAccountPurgeParams{ID: id, PurgeStep: 1}); err != nil {
				return err
			}
		case 1:
			n, err := q.MinimizeAccountAudit(ctx, sqlc.MinimizeAccountAuditParams{UserID: op.UserID, BatchSize: batch})
			if err != nil {
				return err
			}
			if n >= int64(batch) {
				return nil
			}
			if err := q.AdvanceAccountPurge(ctx, sqlc.AdvanceAccountPurgeParams{ID: id, PurgeStep: 2}); err != nil {
				return err
			}
			return audit.Record(ctx, tx, evidence(sessionClient(), op.UserID, "account.audit.minimize", nil))
		case 2:
			remaining, err := q.HasAccountChallenges(ctx, &u.ID)
			if err != nil {
				return err
			}
			if remaining {
				return nil
			} // late inserts retry via ordered L2 on the next pass
			n, err := q.DeleteAccountSessions(ctx, sqlc.DeleteAccountSessionsParams{UserID: u.ID, BatchSize: batch})
			if err != nil {
				return err
			}
			if n > 0 {
				return nil
			}
			n, err = q.PurgeAccountOutbox(ctx, sqlc.PurgeAccountOutboxParams{UserID: &u.ID, BatchSize: batch})
			if err != nil {
				return err
			}
			if n > 0 {
				return nil
			}
			if err := q.DeleteAccountEmailChanges(ctx, u.ID); err != nil {
				return err
			}
			if err := q.DeleteOtherAccountOperations(ctx, sqlc.DeleteOtherAccountOperationsParams{UserID: &u.ID, KeepID: id}); err != nil {
				return err
			}
			n, err = accounts.Erase(ctx, tx, u.ID)
			if err != nil {
				return err
			}
			if n != 1 {
				return errors.New("rights: sealed owner not erased")
			}
			if err := q.ExpireDeletedAddressFence(ctx, op.EmailDigests); err != nil {
				return err
			}
			if err := q.CompleteDeletionLedger(ctx, id); err != nil {
				return err
			}
			if err := q.CompleteAccountPurge(ctx, id); err != nil {
				return err
			}
			result = "completed"
			return audit.Record(ctx, tx, evidence(sessionClient(), op.UserID, "account.delete.complete", map[string]string{"operation_id": id.String()}))
		}
		return audit.Record(ctx, tx, evidence(sessionClient(), op.UserID, "account.delete.purge_step", map[string]string{"step": formatCount(int64(op.PurgeStep))}))
	})
	if err != nil {
		result = ""
	}
	return job, result, err
}

func sessionClient() session.Client { return session.Client{} }
