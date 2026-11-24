#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# UI-only executable: compile the real AppKit controllers with a value-only DTO.
# This intentionally excludes inference/XPC; it is not a full IME or Discord test.
cat > "$TMP/DTO.swift" <<'SWIFT'
public struct ConverterCandidatePresentation: Equatable {
 public var text: String
 public var annotationText: String?
 public var extraValues: [String:String] = [:]
 public init(text: String, annotationText: String? = nil) { self.text = text; self.annotationText = annotationText }
}
SWIFT
xcrun swiftc -emit-library -emit-module -module-name Core "$TMP/DTO.swift" "$ROOT/Core/Sources/Core/Windows/WindowPositioning.swift" -o "$TMP/libCore.dylib" -emit-module-path "$TMP/Core.swiftmodule"
cp "$ROOT/Tools/tests/CandidateWindowScenarios.swift" "$TMP/main.swift"
xcrun swiftc -O -I "$TMP" -L "$TMP" -lCore -Xlinker -rpath -Xlinker "$TMP" "$ROOT/azooKeyMac/InputController/CandidateWindow/BaseCandidateViewController.swift" "$ROOT/azooKeyMac/InputController/CandidateWindow/CandidateView.swift" "$ROOT/azooKeyMac/InputController/WindowPositioning+CoreGraphics.swift" "$TMP/main.swift" -o "$TMP/scenarios"
"$TMP/scenarios"
