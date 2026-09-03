#!/bin/bash
# Builds the client into build/iTunes Remote.app (ad-hoc signed).
#   ./build.sh                      build
#   ./build.sh --run [args...]      build, then launch with args
#   ./build.sh --snapshot X [args]  build, then render the main window to X and quit
# Server overrides for development: --host H --port P --token T
set -euo pipefail
cd "$(dirname "$0")"
APP="build/iTunes Remote.app"
BIN="$APP/Contents/MacOS/iTunesRemote"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$BIN" \
    Sources/Aqua/*.swift Sources/API/*.swift Sources/App/*.swift \
    -framework Cocoa

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>iTunes Remote</string>
  <key>CFBundleDisplayName</key><string>iTunes Remote</string>
  <key>CFBundleIdentifier</key><string>local.stevenbleifer.itunesremote</string>
  <key>CFBundleExecutable</key><string>iTunesRemote</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRequiresAquaSystemAppearance</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force -s - "$APP" >/dev/null 2>&1
echo "built $APP"

case "${1:-}" in
    --run) shift; "$BIN" "$@" & ;;
    --snapshot) out="$2"; shift 2; "$BIN" --snapshot "$out" "$@" ;;
    # Replace the copy in /Applications. Quit it first: overwriting a running
    # bundle leaves the old code mapped and the next launch misbehaves.
    --install)
        pkill -f "iTunes Remote.app/Contents/MacOS/iTunesRemote" 2>/dev/null || true
        sleep 1
        rm -rf "/Applications/iTunes Remote.app"
        cp -R "$APP" "/Applications/iTunes Remote.app"
        echo "installed /Applications/iTunes Remote.app"
        ;;
esac
