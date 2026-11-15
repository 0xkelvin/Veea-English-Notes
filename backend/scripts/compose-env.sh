#!/usr/bin/env bash
# Generate local-only Compose credentials without replacing existing keys or printing them.
set -euo pipefail
umask 077
env_file="${1:?usage: compose-env.sh ENV_FILE}"
if [[ -e "$env_file" || -L "$env_file" ]]; then
  printf 'Keeping existing Compose env file.\n'
  exit 0
fi
command -v openssl >/dev/null || { echo 'openssl is required to generate local keys' >&2; exit 1; }
tmp_file="$(mktemp "${env_file}.tmp.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT
db_key="$(openssl rand -hex 32)"
hmac_key="$(openssl rand -hex 32)"
otp_key="$(openssl rand -hex 32)"
outbox_key="$(openssl rand -hex 32)"
{
  printf '# Generated for local Go Compose only. Keep these keys across down/up.\n'
  printf '# Port overrides and key formats: backend/.env.example\n'
  printf 'VEEA_LOCAL_DB_PASSWORD=%s\n' "$db_key"
  printf 'VEEA_EMAIL_HMAC_KEY=%s\n' "$hmac_key"
  printf 'VEEA_OTP_KEY=%s\n' "$otp_key"
  printf 'VEEA_OUTBOX_KEY=1:%s\n' "$outbox_key"
} > "$tmp_file"
# Exclusive publication: another invocation or existing user file always wins.
if ln "$tmp_file" "$env_file" 2>/dev/null; then
  printf 'Created private Compose env file with independent local keys.\n'
elif [[ -e "$env_file" || -L "$env_file" ]]; then
  printf 'Keeping existing Compose env file.\n'
else
  echo 'Cannot create the Compose env file' >&2
  exit 1
fi
