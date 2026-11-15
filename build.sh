#!/bin/sh
# Builds the command-line tool (bin/lgpbp) and the menu bar app (LG PBP.app).
set -e
cd "$(dirname "$0")"

mkdir -p bin
swiftc -O Sources/LGMonitor.swift Sources/cli/main.swift -o bin/lgpbp

APP="LG PBP.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O Sources/*.swift Sources/app/main.swift -o "$APP/Contents/MacOS/LG PBP"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LG PBP</string>
    <key>CFBundleDisplayName</key><string>LG PBP</string>
    <key>CFBundleExecutable</key><string>LG PBP</string>
    <key>CFBundleIdentifier</key><string>local.lgpbp.menubar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# Sign with a real developer identity when one exists. macOS ties the Accessibility
# permission to the signature: an ad-hoc signature changes on every build, which
# silently invalidates the permission, while a developer identity keeps it.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
if [ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "Built bin/lgpbp and $APP (signed with developer identity)"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1
    echo "Built bin/lgpbp and $APP (ad-hoc signed: Accessibility permission must be re-granted after each build)"
fi
