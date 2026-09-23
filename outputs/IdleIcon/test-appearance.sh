#!/bin/zsh
set -eu
ROOT="${0:A:h}"
CHECKS="$ROOT/../../work"
mkdir -p "$CHECKS/qa-v100/appearance"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -module-cache-path "$CHECKS/build/module-cache" \
 "$ROOT/Source/IconCutout.swift" "$ROOT/Source/IconPalette.swift" "$ROOT/Source/IconContour.swift" "$ROOT/Source/LampModels.swift" "$ROOT/Source/SceneLights.swift" "$ROOT/Source/IconRenderer.swift" "$ROOT/Source/InspectorCanvas.swift" "$ROOT/Tests/Appearance/main.swift" \
 -framework AppKit -framework MetalKit -framework Vision -framework CoreImage -o "$CHECKS/qa-v100/check-appearance"
"$CHECKS/qa-v100/check-appearance" "$CHECKS/qa-v100/appearance"

xcrun swift -module-cache-path "$CHECKS/build/module-cache" "$ROOT/Tests/Shadow/main.swift" "$CHECKS/qa-v100/appearance"
