#!/usr/bin/env bash
# Native tests for the offline camera tutor (macOS with swiftc).
# Compiles the same Foundation/CryptoKit-only shared files the Runner target uses
# (policy, download policy, lifecycle/runtime core) with synthetic fixtures and a
# scripted fake model backend. No network, no model weights, no device needed.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
veea_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/veea-offline-tutor-tests.XXXXXX")"
trap 'rm -rf -- "$veea_test_dir"' EXIT
cd "$project_root"
swiftc -module-cache-path "$veea_test_dir/module-cache" -swift-version 6 \
  ios/OfflineTutorShared/OfflineTutorPolicy.swift \
  ios/OfflineTutorShared/OfflineTutorDownloadPolicy.swift \
  ios/OfflineTutorShared/OfflineTutorLifecycle.swift \
  test/native/offline_tutor/main.swift -o "$veea_test_dir/offline-tutor-tests"
VEEA_TEST_TMP="$veea_test_dir" "$veea_test_dir/offline-tutor-tests"
