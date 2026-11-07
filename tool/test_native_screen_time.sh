#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
veea_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/veea-native-tests.XXXXXX")"
trap 'rm -rf -- "$veea_test_dir"' EXIT
cd "$project_root"
swiftc -module-cache-path "$veea_test_dir/module-cache" -swift-version 6 ios/Runner/GateAccessState.swift \
  test/native/gate_access_state/main.swift -o "$veea_test_dir/shortcut-tests"
"$veea_test_dir/shortcut-tests"
swiftc -module-cache-path "$veea_test_dir/module-cache" -swift-version 6 ios/NativeGateShared/NativeGatePolicy.swift \
  ios/NativeGateShared/NativeGateStore.swift \
  ios/NativeGateShared/NativeGateGrantCoordinator.swift \
  test/native/native_gate/main.swift -o "$veea_test_dir/native-tests"
"$veea_test_dir/native-tests"
