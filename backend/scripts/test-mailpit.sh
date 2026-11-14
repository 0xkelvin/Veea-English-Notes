#!/usr/bin/env bash
# Local Mailpit (Docker) for developing and testing email delivery.
#
#   scripts/test-mailpit.sh start   # start Mailpit, wait until ready
#   scripts/test-mailpit.sh stop    # remove the container and every captured email
#
# SMTP listens on 127.0.0.1:1025 (VEEA_SMTP_ADDR=localhost:1025, the default) and the web UI and
# API on http://127.0.0.1:8025. Both are bound to loopback only. Mailpit keeps mail in memory and
# never relays it anywhere, so nothing sent here leaves the machine.
set -euo pipefail

NAME="${VEEA_MAILPIT_CONTAINER:-veea-mailpit}"
IMAGE="${VEEA_MAILPIT_IMAGE:-axllent/mailpit:v1.33.1}"
SMTP_PORT="${VEEA_MAILPIT_SMTP_PORT:-1025}"
HTTP_PORT="${VEEA_MAILPIT_HTTP_PORT:-8025}"

case "${1:-}" in
start)
  if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" \
      -p "127.0.0.1:$SMTP_PORT:1025" -p "127.0.0.1:$HTTP_PORT:8025" \
      "$IMAGE" >/dev/null
  fi
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:$HTTP_PORT/api/v1/info" >/dev/null 2>&1; then
      echo "smtp=127.0.0.1:$SMTP_PORT api=http://127.0.0.1:$HTTP_PORT"
      exit 0
    fi
    sleep 1
  done
  echo "Mailpit did not become ready in 30 s" >&2
  exit 1
  ;;
stop)
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  ;;
*)
  echo "usage: $0 start|stop" >&2
  exit 2
  ;;
esac
