#!/bin/zsh
set -eu
ROOT="${0:A:h}"
CHECKS="$ROOT/../../work"
mkdir -p "$CHECKS/build/module-cache" "$CHECKS/qa-v100/geometry"
xcrun swiftc -swift-version 5 -Onone -target arm64-apple-macosx14.0 \
  -module-cache-path "$CHECKS/build/module-cache" \
  "$ROOT/Source/IconCutout.swift" "$ROOT/Source/IconPalette.swift" "$ROOT/Source/IconContour.swift" "$ROOT/Source/LampModels.swift" "$ROOT/Source/SceneLights.swift" "$ROOT/Source/IconRenderer.swift" "$ROOT/Source/DesktopCanvas.swift" "$ROOT/Tests/main.swift" \
  -framework AppKit -framework MetalKit -framework Vision -framework CoreImage -o "$CHECKS/qa-v100/check-geometry"
"$CHECKS/qa-v100/check-geometry" "$CHECKS/qa-v100/geometry"
