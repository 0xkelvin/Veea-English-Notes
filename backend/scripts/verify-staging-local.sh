#!/usr/bin/env bash
# Local evidence only. Never deploys, publishes content, or opens a rollout gate.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../.."
VEEA_VERIFY_ROOT="$PWD"
VEEA_VERIFY_EVIDENCE="${1:-$(mktemp -d /tmp/veea-staging-local.XXXXXX)}"
mkdir -p "$VEEA_VERIFY_EVIDENCE"
VEEA_VERIFY_EVIDENCE="$(cd "$VEEA_VERIFY_EVIDENCE" && pwd)"
# Credentials for a running deployment are not inputs to disposable tests.
unset VEEA_DATABASE_URL VEEA_MAINTENANCE_DATABASE_URL VEEA_RESEND_API_KEY
unset VEEA_EMAIL_HMAC_KEY VEEA_OUTBOX_KEY VEEA_OTP_KEY VEEA_EMAIL_SENDER
for command in go flutter docker python3 pg_dump pg_restore; do
  command -v "$command" >/dev/null || { echo "missing local prerequisite: $command" >&2; exit 2; }
done
{
  date -u '+%Y-%m-%dT%H:%M:%SZ'
  git rev-parse HEAD
  git status --short
  go version
  pg_dump --version
  pg_restore --version
  flutter --version
} > "$VEEA_VERIFY_EVIDENCE/environment.txt"
run() {
  local name="$1"; shift
  printf 'Running %s\n' "$name"
  if "$@" > "$VEEA_VERIFY_EVIDENCE/$name.log" 2>&1; then
    printf '%s\tpassed\n' "$name" >> "$VEEA_VERIFY_EVIDENCE/checks.tsv"
  else
    printf '%s\tfailed\n' "$name" >> "$VEEA_VERIFY_EVIDENCE/checks.tsv"
    echo "failed: $name; inspect private evidence" >&2
    return 1
  fi
}
: > "$VEEA_VERIFY_EVIDENCE/checks.tsv"
run services-postgres backend/scripts/test-postgres.sh start
run services-mailpit backend/scripts/test-mailpit.sh start
export VEEA_TEST_DATABASE_URL="$(backend/scripts/test-postgres.sh url)"
export VEEA_TEST_SMTP_ADDR="127.0.0.1:${VEEA_MAILPIT_SMTP_PORT:-1025}"
export VEEA_TEST_MAILPIT_API="http://127.0.0.1:${VEEA_MAILPIT_HTTP_PORT:-8025}"
run go-check make -C backend check
run go-build make -C backend build
run sqlc-verify make -C backend sqlc-verify
run alerts make -C backend test-alerts
cd "$VEEA_VERIFY_ROOT/backend"
run tagged-vet go vet -tags=integration,fluttere2e,restoredrill ./...
run go-race go test -race -tags=integration -count=1 -json ./...
cd "$VEEA_VERIFY_ROOT"
run restore backend/scripts/test-restore-drill.sh
run flutter-analysis flutter analyze
run flutter-regressions flutter test test/screens/cartridge_library_screen_test.dart \
  test/models/cartridge_test.dart test/providers/cartridge_provider_test.dart \
  test/providers/cartridge_server_test.dart test/data/sync test/data/go_session_test.dart \
  test/providers/go_auth_provider_test.dart test/data/app_database_test.dart \
  test/screens/go_account_screen_test.dart --reporter json
export VEEA_FLUTTER_E2E_REPORT="$VEEA_VERIFY_EVIDENCE/flutter-go.jsonl"
run flutter-go-host make -C backend test-flutter-go
cd "$VEEA_VERIFY_ROOT/admin_console"
run admin-analysis flutter analyze
run admin-build flutter build web --release --no-web-resources-cdn
run admin-tests flutter test --reporter json
cd "$VEEA_VERIFY_ROOT"
export VEEA_ADMIN_E2E_REPORT="$VEEA_VERIFY_EVIDENCE/flutter-admin.jsonl"
run flutter-admin-host make -C backend test-flutter-admin
run diff-worktree git diff --check
run diff-index git diff --cached --check
printf 'Local checks passed. Private evidence: %s\nSync rollout gate was not opened.\n' "$VEEA_VERIFY_EVIDENCE"
