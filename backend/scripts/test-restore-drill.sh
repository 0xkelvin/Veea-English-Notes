#!/usr/bin/env bash
# Synthetic pg_dump/pg_restore drill. pgtest refuses non-loopback URLs and owns both databases.
set -euo pipefail
cd "$(dirname "$0")/.."
for command in pg_dump pg_restore go; do
  command -v "$command" >/dev/null || { echo "missing local prerequisite: $command" >&2; exit 2; }
done
scripts/test-postgres.sh start >/dev/null
export VEEA_TEST_DATABASE_URL="$(scripts/test-postgres.sh url)"
exec go test -race -tags=integration,restoredrill -count=1 -json ./test/integration \
  -run '^TestStagingRestore_BackupAndDeletionReplay$'
