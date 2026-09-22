#!/bin/zsh
set -eu
ROOT="${0:A:h}"
CHECKS="$ROOT/../../work"
mkdir -p "$CHECKS/qa-v061/appearance"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -module-cache-path "$CHECKS/build/module-cache" \
 "$ROOT/Source/IconCutout.swift" "$ROOT/Source/IconPalette.swift" "$ROOT/Source/IconContour.swift" "$ROOT/Source/IconRenderer.swift" "$ROOT/Source/InspectorCanvas.swift" "$ROOT/Tests/Appearance/main.swift" \
 -framework AppKit -framework MetalKit -framework Vision -framework CoreImage -o "$CHECKS/check-appearance"
"$CHECKS/check-appearance" "$CHECKS/qa-v061/appearance"

xcrun swift -module-cache-path "$CHECKS/build/module-cache" "$ROOT/Tests/Shadow/main.swift" "$CHECKS/qa-v061/appearance"
