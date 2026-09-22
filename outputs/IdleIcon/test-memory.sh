#!/bin/zsh
set -eu
ROOT="${0:A:h}"
CHECKS="$ROOT/../../work"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -module-cache-path "$CHECKS/build/module-cache" \
 "$ROOT/Source/SystemMonitor.swift" "$ROOT/Source/MemoryPlayground.swift" "$ROOT/Tests/Memory/main.swift" \
 -framework AppKit -framework Metal -framework UniformTypeIdentifiers -o "$CHECKS/check-memory"
"$CHECKS/check-memory" "$CHECKS/qa-v04" "$@"
