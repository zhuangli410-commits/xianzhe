#!/bin/zsh
set -eu
ROOT="${0:A:h}"
CHECKS="$ROOT/../../work/qa-v06"
mkdir -p "$CHECKS"
xcrun swiftc -swift-version 5 -module-cache-path "$ROOT/../../work/build/module-cache" "$ROOT/Source/PerformanceBudget.swift" "$ROOT/Tests/Performance/main.swift" -o "$CHECKS/check-performance"
"$CHECKS/check-performance"
