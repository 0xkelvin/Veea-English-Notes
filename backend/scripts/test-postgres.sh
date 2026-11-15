#!/usr/bin/env bash
# Disposable local PostgreSQL (Docker) for the Go integration tests.
#
#   scripts/test-postgres.sh start   # start the container, wait until ready, print the URL
#   scripts/test-postgres.sh url     # print VEEA_TEST_DATABASE_URL
#   scripts/test-postgres.sh stop    # remove the container and its data
#
# The container publishes on 127.0.0.1 only, keeps its data in tmpfs, uses trust
# authentication and disables fsync. It is for tests and nothing else: never put
# real data in it and never point it at anything but localhost.
set -euo pipefail

NAME="${VEEA_TEST_PG_CONTAINER:-veea-test-pg}"
PORT="${VEEA_TEST_PG_PORT:-54329}"
IMAGE="${VEEA_TEST_PG_IMAGE:-postgres:17-alpine}"
URL="postgres://postgres@127.0.0.1:$PORT/postgres"

case "${1:-}" in
start)
  if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" \
      -e POSTGRES_HOST_AUTH_METHOD=trust \
      -p "127.0.0.1:$PORT:5432" \
      --tmpfs /var/lib/postgresql/data \
      "$IMAGE" -c fsync=off -c synchronous_commit=off -c full_page_writes=off >/dev/null
  fi
  for _ in $(seq 1 60); do
    if docker exec "$NAME" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then
      echo "$URL"
      exit 0
    fi
    sleep 1
  done
  echo "PostgreSQL did not become ready in 60 s" >&2
  exit 1
  ;;
url)
  echo "$URL"
  ;;
stop)
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  ;;
*)
  echo "usage: $0 start|url|stop" >&2
  exit 2
  ;;
esac
