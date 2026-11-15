#!/usr/bin/env bash
# Regenerates sqlc output and fails if it differs from what is on disk, which catches
# both stale checked-in code and non-deterministic generation.
#
#   scripts/sqlc-verify.sh "<sqlc command>" <output dir>
set -euo pipefail

sqlc_cmd="$1"
out_dir="$2"

fingerprint() {
  find "$out_dir" -type f | sort | xargs shasum -a 256
}

before="$(fingerprint)"
$sqlc_cmd generate
after="$(fingerprint)"

if [ "$before" != "$after" ]; then
  echo "sqlc output was stale or non-deterministic; run 'make sqlc' and commit the result" >&2
  diff <(echo "$before") <(echo "$after") >&2 || true
  exit 1
fi
echo "sqlc output is up to date and reproducible"
