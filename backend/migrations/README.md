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

Rules:

- Up-only. Never edit a file once it has been applied in a shared environment.
- Use `IF NOT EXISTS` in every statement. A test re-runs every file to check this.
- Keep `;` out of comments: goose splits statements on line-ending semicolons.
- Add a new file with the next number. Do not drop a column in the same release that removes its code.
- Run with `bin/migrate up`, never from API startup.
