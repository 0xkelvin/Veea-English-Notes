# Migrations

Goose SQL migrations for the Go backend, embedded into the `migrate` binary and read
by sqlc as the schema source (see `../sqlc.yaml`).

| File | Contents (TRD 01 section) |
|---|---|
| `00001_users.sql` | `users` (6.2) |
| `00002_otp.sql` | `otp_challenges`, `otp_cooldowns` (6.3, 6.4) |
| `00003_sessions.sql` | `sessions`, `refresh_tokens_consumed` (6.5, 6.6) |
| `00004_email_outbox.sql` | `email_outbox` (6.7) |
| `00005_audit_events.sql` | `audit_events` (6.8) |
| `00006_rate_limit_counters.sql` | `rate_limit_counters` (6.9) |
| `00007_cleanup_indexes.sql` | indexes for the cleanup jobs and their cascades (6.10) |
| `00008_session_management.sql` | extend revocation reasons for user revocation/logout-all (TRD 02) |
| `00009_account_profile_email_change.sql` | profile/email revisions, owned requests and expiry index, paired OTP bindings/indexes, notification templates and email-change revocation (TRD 03) |
| `00014_entitlements.sql` | `users.entitlement_revision`, `entitlement_grants` (manual Premium periods, one open per account, RESTRICT for the purge, 366-day period check, generated `period_end`), `entitlement_premium_until()` (TRD 09) |
| `00013_rbac_bootstrap_marker.sql` | singleton `rbac_bootstrap` marker (first Super Admin bootstrap time), backfilled from existing Super Admins or bootstrap events (TRD 08) |
| `00012_rbac_admin.sql` | role revision, saved suspension (`resume_status`, reason, ticket, actor) and its consistency constraint, admin revocation reasons, admin list/prefix/Super Admin indexes (TRD 06) |

Rules:

- Up-only. Never edit a file once it has been applied in a shared environment.
- Use `IF NOT EXISTS` where PostgreSQL supports it. Constraint replacement in `00008`/`00009` uses `DROP CONSTRAINT IF EXISTS` and an atomic re-add instead. A test re-runs every file to check this.
- Keep `;` out of comments: goose splits statements on line-ending semicolons.
- Add a new file with the next number. Do not drop a column in the same release that removes its code.
- Run with `bin/migrate up`, never from API startup.
