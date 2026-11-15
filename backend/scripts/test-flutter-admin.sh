#!/usr/bin/env bash
# TRD 07: the admin console (admin_console/) against the real Go router, its OpenAPI response
# checker and an isolated local PostgreSQL. Loopback only; synthetic accounts.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/test-postgres.sh start >/dev/null
export VEEA_TEST_DATABASE_URL="$(scripts/test-postgres.sh url)"
export VEEA_ADMIN_E2E_REPORT="${VEEA_ADMIN_E2E_REPORT:-$(mktemp -t veea-admin-console.XXXXXX)}"
exec go test -race -tags=integration,fluttere2e -count=1 -json \
  ./test/integration -run '^TestFlutterGo_AdminConsole$'
