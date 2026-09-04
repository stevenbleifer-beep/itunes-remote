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
    -framework Cocoa -framework MediaPlayer

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
  <!-- Plain HTTP is fine on the LAN (.local) and inside the Tailscale
       tunnel, which is WireGuard-encrypted end to end; ATS only knows the
       second one by name. -->
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsLocalNetworking</key><true/>
    <key>NSExceptionDomains</key><dict>
      <key>ts.net</key><dict>
        <key>NSIncludesSubdomains</key><true/>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
      </dict>
    </dict>
  </dict>
</dict></plist>
PLIST
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc for development. With ITR_SIGN_IDENTITY set to a "Developer ID
# Application: …" identity, a real signature with the hardened runtime, which
# is what notarization needs; package.sh does the notarizing.
if [ -n "${ITR_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp -s "$ITR_SIGN_IDENTITY" "$APP"
    echo "signed as $ITR_SIGN_IDENTITY"
else
    codesign --force -s - "$APP" >/dev/null 2>&1
fi
echo "built $APP"

case "${1:-}" in
    --run) shift; "$BIN" "$@" & ;;
    --snapshot) out="$2"; shift 2; "$BIN" --snapshot "$out" "$@" ;;
    # Replace the copy in /Applications. Quit it first: overwriting a running
    # bundle leaves the old code mapped and the next launch misbehaves.
    # Update the installed copy in place. Never delete and recreate the
    # bundle: the Dock pins an app by that directory, and a custom icon
    # pasted in Finder lives on the directory itself, so removing it loses
    # both. rsync replaces the contents and leaves the bundle where it is.
    # Update the installed copy in place. Never delete and recreate the
    # bundle: the Dock pins an app by that directory. rsync replaces the
    # contents and leaves the bundle where it is. The icon is now the bundle's
    # real AppIcon.icns, which the Dock always honours, so any old
    # Finder-pasted custom icon is removed to stop the two fighting.
    --install)
        pkill -f "iTunes Remote.app/Contents/MacOS/iTunesRemote" 2>/dev/null || true
        sleep 1
        dest="/Applications/iTunes Remote.app"
        mkdir -p "$dest"
        rsync -a --delete "$APP/" "$dest/"
        rm -f "$dest/Icon"$'\r' 2>/dev/null || true
        xattr -c "$dest" 2>/dev/null || true
        touch "$dest"
        # Nudge Launch Services and the Dock so the tile drops its cached icon.
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest" 2>/dev/null || true
        killall Dock 2>/dev/null || true
        echo "installed $dest"
        ;;
esac
