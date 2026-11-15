#!/usr/bin/env bash
# The real Go router + isolated local PostgreSQL + SMTP/Mailpit, driven by Dart.
# The fixture's temporary sync gate is never the rollout database's gate.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/test-postgres.sh start
scripts/test-mailpit.sh start
export VEEA_TEST_DATABASE_URL="$(scripts/test-postgres.sh url)"
export VEEA_TEST_SMTP_ADDR="127.0.0.1:${VEEA_MAILPIT_SMTP_PORT:-1025}"
export VEEA_TEST_MAILPIT_API="http://127.0.0.1:${VEEA_MAILPIT_HTTP_PORT:-8025}"
export VEEA_FLUTTER_E2E_REPORT="${VEEA_FLUTTER_E2E_REPORT:-$(mktemp -t veea-flutter-go.XXXXXX)}"
exec go test -race -tags=integration,fluttere2e -count=1 -json \
  ./test/integration -run '^TestFlutterGo_EndToEnd$'
