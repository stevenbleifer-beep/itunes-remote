#!/bin/bash
# Builds the client into build/iTunes Remote.app (ad-hoc signed).
#   ./build.sh                      build
#   ./build.sh --run [args...]      build, then launch with args
#   ./build.sh --snapshot X [args]  build, then render the main window to X and quit
# Server overrides for development: --host H --port P --token T
set -euo pipefail
cd "$(dirname "$0")"
# ITR_VARIANT=music builds "Apple Music Remote", the app for the Apple Music
# library in Music.app on this Mac: its own name, bundle identifier, icon
# and settings, so it and iTunes Remote never touch each other.
if [ "${ITR_VARIANT:-itunes}" = "music" ]; then
    NAME="Apple Music Remote"; EXE="AppleMusicRemote"; BUNDLE_ID="local.stevenbleifer.applemusicremote"
    ICON="Resources/AppIcon-AppleMusic.icns"; VARIANT="music"
else
    NAME="iTunes Remote"; EXE="iTunesRemote"; BUNDLE_ID="local.stevenbleifer.itunesremote"
    ICON="Resources/AppIcon.icns"; VARIANT="itunes"
fi
APP="build/$NAME.app"
BIN="$APP/Contents/MacOS/$EXE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$BIN" \
    Sources/Aqua/*.swift Sources/API/*.swift Sources/App/*.swift \
    -framework Cocoa -framework MediaPlayer -framework MusicKit

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>ITRVariant</key><string>$VARIANT</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Apple Music catalogue search, on the Apple Music library only. -->
  <key>NSAppleMusicUsageDescription</key><string>Searches Apple Music and adds what you pick to your library.</string>
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
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# The daemon itself, for "This Mac": the Apple Music library in Music.app.
# The setup assistant runs its installer, which puts it under Application
# Support as a LaunchAgent, the same way it is installed on the iTunes Mac.
rm -rf "$APP/Contents/Resources/daemon"
mkdir -p "$APP/Contents/Resources/daemon"
rsync -a --exclude __pycache__ --exclude tests --exclude bin \
    ../daemon/itunes_remote ../daemon/scripts ../daemon/check.py "../daemon/Install iTunes Remote Daemon.command" \
    "$APP/Contents/Resources/daemon/"
[ -x ../daemon/bin/musiclibdump ] || ../daemon/tools/build.sh
# The fine-tune script, run by Controls ▸ Train Curator on My Edits…
cp finetune/finetune.sh "$APP/Contents/Resources/finetune.sh"
chmod 755 "$APP/Contents/Resources/finetune.sh"
# The bundled Ollama, when fetch-ollama.sh has been run. Without it the app
# still works with an Ollama app installed separately.
rm -rf "$APP/Contents/Helpers"
if [ -x Vendor/ollama/ollama ]; then
    # Only executables under Helpers: codesign treats anything else there
    # as unsigned nested code and refuses to sign the app.
    mkdir -p "$APP/Contents/Helpers/ollama"
    cp Vendor/ollama/ollama Vendor/ollama/llama-server "$APP/Contents/Helpers/ollama/"
    cp Vendor/ollama/LICENSE "$APP/Contents/Resources/Ollama-LICENSE.txt" 2>/dev/null || true
    cp Vendor/ollama/VERSION "$APP/Contents/Resources/Ollama-VERSION.txt" 2>/dev/null || true
fi
# musiclibdump reads Music.app's library for the bundled daemon; Helpers,
# because it is a Mach-O and codesign wants nested code there, not in Resources.
mkdir -p "$APP/Contents/Helpers"
cp ../daemon/bin/musiclibdump "$APP/Contents/Helpers/musiclibdump"
# Ad-hoc for development. With ITR_SIGN_IDENTITY set to a "Developer ID
# Application: …" identity, a real signature with the hardened runtime, which
# is what notarization needs; package.sh does the notarizing.
if [ -n "${ITR_SIGN_IDENTITY:-}" ]; then
    # Nested executables first, each with the hardened runtime, then the app.
    for h in "$APP"/Contents/Helpers/ollama/ollama "$APP"/Contents/Helpers/ollama/llama-server "$APP"/Contents/Helpers/musiclibdump; do
        [ -f "$h" ] && codesign --force --options runtime --timestamp -s "$ITR_SIGN_IDENTITY" "$h"
    done
    codesign --force --options runtime --timestamp -s "$ITR_SIGN_IDENTITY" "$APP"
    echo "signed as $ITR_SIGN_IDENTITY"
else
    for h in "$APP"/Contents/Helpers/ollama/ollama "$APP"/Contents/Helpers/ollama/llama-server "$APP"/Contents/Helpers/musiclibdump; do
        [ -f "$h" ] && codesign --force -s - "$h" >/dev/null 2>&1
    done
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
        pkill -f "$NAME.app/Contents/MacOS/$EXE" 2>/dev/null || true
        sleep 1
        dest="/Applications/$NAME.app"
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
