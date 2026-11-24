#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/Tools/tests/ConfigIsolationScenarios.swift" "$TMP/main.swift"
xcrun swiftc "$ROOT/Core/Sources/Core/Configs/Config.swift" "$ROOT/Core/Sources/Core/Configs/AppGroup.swift" "$TMP/main.swift" -o "$TMP/check"
defaults export group.local.tenarai.inputmethod.tenarai "$TMP/before.plist"
TENARAI_TEST_ROOT="$TMP" "$TMP/check"
defaults export group.local.tenarai.inputmethod.tenarai "$TMP/after.plist"
cmp "$TMP/before.plist" "$TMP/after.plist"
echo 'PASS production preferences unchanged'
