#!/bin/zsh
set -eu
ROOT="${0:A:h}"
DEST="$ROOT/../闲着.app"
BUILD="$ROOT/../../work/build"
mkdir -p "$BUILD" "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT/Source/SystemMonitor.swift" "$ROOT/Source/MemoryPlayground.swift" "$ROOT/Source/Dashboard.swift" "$ROOT/Source/IconCutout.swift" "$ROOT/Source/IconPalette.swift" "$ROOT/Source/IconContour.swift" "$ROOT/Source/IconRenderer.swift" "$ROOT/Source/DesktopCanvas.swift" "$ROOT/Source/InspectorCanvas.swift" "$ROOT/Source/PerformanceBudget.swift" "$ROOT/Source/main.swift" \
  -framework AppKit -framework Metal -framework MetalKit -framework UniformTypeIdentifiers -framework Vision -framework CoreImage \
  -o "$DEST/Contents/MacOS/IdleIcon"
cat > "$DEST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.xianzhe.idleicon</string>
<key>CFBundleName</key><string>闲着</string>
<key>CFBundleDisplayName</key><string>闲着</string>
<key>CFBundleExecutable</key><string>IdleIcon</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.1</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
PLIST
if [[ ! -f "$ROOT/Resources/AppIcon.icns" || "$ROOT/Tools/MakeIcon.swift" -nt "$ROOT/Resources/AppIcon.icns" ]]; then
  mkdir -p "$ROOT/Resources"
  xcrun swift -module-cache-path "$BUILD/module-cache" "$ROOT/Tools/MakeIcon.swift" "$BUILD/AppIcon.iconset"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
fi
cp "$ROOT/Resources/AppIcon.icns" "$DEST/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$DEST"
codesign --verify --strict --verbose=2 "$DEST"
print "Built: $DEST"
