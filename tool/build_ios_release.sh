#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${VEEA_APPLE_PRO_PRODUCT_ID:-}" != 'com.nintran.veeaEnglishApp.pro' ]]; then
  echo 'Set VEEA_APPLE_PRO_PRODUCT_ID to com.nintran.veeaEnglishApp.pro before building.' >&2
  exit 2
fi

# Validate the authority before compiling it into the application. Print only
# the normalized public origin on success.
api_origin="$(python3 - <<'PY'
import os
import re
import sys
from urllib.parse import urlsplit

raw = os.environ.get("VEEA_API_BASE_URL", "")
try:
    if not re.fullmatch(r"[\x21-\x7e]+", raw) or any(c in raw for c in "?#\\%@"):
        raise ValueError
    url = urlsplit(raw)
    host, port = url.hostname, url.port
    if url.scheme != "https" or not host or url.path.strip("/") or url.netloc.endswith(":"):
        raise ValueError
    if (any(c in url.netloc for c in "[]") or re.fullmatch(r"(?:[0-9]+|0x[0-9a-f]+)(?:\.(?:[0-9]+|0x[0-9a-f]+))*", host)
            or host.startswith("localhost.") or host.endswith(".localhost")):
        raise ValueError
    if "." not in host or len(host) > 253 or not all(
        re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
        for label in host.split(".")
    ):
        raise ValueError
    if port == 0:
        raise ValueError
except ValueError:
    sys.exit("Set VEEA_API_BASE_URL to a root HTTPS origin with a DNS hostname (no localhost, IP address, path, credentials, query or fragment).")
print(f"https://{host}" + (f":{port}" if port not in (None, 443) else ""))
PY
)" || exit 2

# Only forward arguments that cannot change the entry point or compiled defines.
args=()
while (( $# )); do
  case "$1" in
    --build-number|--build-name|--export-method|--export-options-plist|--split-debug-info)
      if (( $# < 2 )) || [[ -z "$2" || "$2" == -* ]]; then
        echo 'A release build option requires a value.' >&2
        exit 2
      fi
      argument="$1=$2"
      shift 2
      ;;
    --build-number=?*|--build-name=?*|--export-method=?*|--export-options-plist=?*|--split-debug-info=?*|--obfuscate|--no-pub)
      argument="$1"
      shift
      ;;
    *)
      echo 'Unsupported release build argument. See docs/first-paid-release.md.' >&2
      exit 2
      ;;
  esac
  if [[ "$argument" == --build-number=* ]]; then
    build_number="${argument#*=}"
    if [[ ! "$build_number" =~ ^[0-9]{1,4}(\.[0-9]{1,2}){0,2}$ || "${build_number%%.*}" =~ ^0+$ ]]; then
      echo 'Use up to three numeric iOS build components: a positive major (1–4 digits), then optional minor and patch (1–2 digits each).' >&2
      exit 2
    fi
  fi
  args+=("$argument")
done

exec flutter build ipa --release \
  --dart-define="VEEA_API_BASE_URL=$api_origin" \
  --dart-define="VEEA_APPLE_PRO_PRODUCT_ID=$VEEA_APPLE_PRO_PRODUCT_ID" \
  ${args[@]+"${args[@]}"}
