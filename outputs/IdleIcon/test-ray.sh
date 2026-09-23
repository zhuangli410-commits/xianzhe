#!/bin/zsh
set -eu
ROOT="${0:A:h}"
BUILD="$ROOT/../../work/qa-v100"
mkdir -p "$BUILD"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -module-cache-path "$ROOT/../../work/build/module-cache" \
  "$ROOT/Source/IconCutout.swift" "$ROOT/Source/IconPalette.swift" "$ROOT/Source/IconContour.swift" "$ROOT/Source/LampModels.swift" "$ROOT/Source/SceneLights.swift" "$ROOT/Source/IconRenderer.swift" "$ROOT/Tests/Ray/main.swift" \
  -framework AppKit -framework Metal -framework MetalKit -framework UniformTypeIdentifiers -framework Vision -framework CoreImage -o "$BUILD/check-ray"
"$BUILD/check-ray"
