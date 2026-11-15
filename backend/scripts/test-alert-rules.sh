#!/usr/bin/env bash
# TRD 08: validate and unit-test the Prometheus alert rules with promtool. Offline: uses a local
# promtool when present, otherwise the pinned prom/prometheus image (no other network access).
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=monitoring/prometheus
IMAGE="${VEEA_PROMTOOL_IMAGE:-prom/prometheus:v2.49.1}"

if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  cp "$DIR"/gen_tests.py "$DIR"/veea-alerts.yml "$tmp"/
  python3 "$tmp"/gen_tests.py
  if ! cmp -s "$tmp"/veea-alerts.test.yml "$DIR"/veea-alerts.test.yml; then
    echo "veea-alerts.test.yml is stale: run python3 $DIR/gen_tests.py" >&2
    exit 1
  fi
fi

run_promtool() {
  if command -v promtool >/dev/null; then
    (cd "$DIR" && command promtool "$@")
  else
    docker run --rm --entrypoint promtool -v "$PWD/$DIR:/rules:ro" -w /rules "$IMAGE" "$@"
  fi
}
run_promtool check rules veea-alerts.yml
run_promtool test rules veea-alerts.test.yml
