#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/Tools/tests/CapsLockScenarios.swift" "$TMP/main.swift"
xcrun swiftc -emit-library -emit-module -module-name Core "$ROOT/Core/Sources/Core/InputUtils/KeyEventCore.swift" -o "$TMP/libCore.dylib" -emit-module-path "$TMP/Core.swiftmodule"
xcrun swiftc -I "$TMP" -L "$TMP" -lCore -Xlinker -rpath -Xlinker "$TMP" "$ROOT/azooKeyMac/InputController/NSEvent.swift" "$TMP/main.swift" -o "$TMP/check"
"$TMP/check"
