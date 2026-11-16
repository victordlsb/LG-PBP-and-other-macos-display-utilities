#!/bin/sh
# Builds the command-line tool (bin/lgpbp) and the menu bar app, and installs the app
# as /Applications/LG PBP.app. The app is assembled in a temporary folder so that the
# installed copy is the only one on the Mac: a second copy in the repo shows up in
# Spotlight under the same name and ends up running alongside the installed one.
set -e
cd "$(dirname "$0")"

mkdir -p bin
swiftc -O Sources/LGMonitor.swift Sources/cli/main.swift -o bin/lgpbp

DEST="/Applications/LG PBP.app"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/LG PBP.app"
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
# Revoked certificates still show up as "valid" in the keychain listing, but macOS
# treats an app signed with one as malware and offers to move it to the Bin, so
# skip any identity flagged CSSMERR_TP_CERT_REVOKED. Signing by SHA-1 hash keeps
# the choice unambiguous when two certificates share a name.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' | grep -v 'CSSMERR' | awk '{print $2; exit}')
if [ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    if spctl -a -t exec "$APP" 2>&1 | grep -q REVOKED; then
        echo "WARNING: the signing certificate has been revoked; nothing was installed." >&2
        echo "Create a new Apple Development certificate in Xcode and delete the old one." >&2
        exit 1
    fi
    SIGNED="signed with developer identity"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1
    SIGNED="ad-hoc signed: Accessibility permission must be re-granted after each build"
fi

# Replace the installed copy. Quit a running instance first and start the new one
# afterwards, so the menu bar never keeps running the old build.
RUNNING=0
if pgrep -x "LG PBP" >/dev/null 2>&1; then
    RUNNING=1
    pkill -x "LG PBP" || true
    sleep 1
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
rm -rf "LG PBP.app"   # the copy older versions of this script left in the repo
[ "$RUNNING" = 1 ] && open "$DEST"

echo "Built bin/lgpbp and installed $DEST ($SIGNED)"
