#!/bin/bash
# Builds the download: a disk image holding the app, the daemon folder with
# its double-click installer, and a Read Me.
#
#   ./package.sh                         ad-hoc signed, for trying out
#   ITR_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./package.sh
#   ITR_SIGN_IDENTITY=… ITR_NOTARY_PROFILE=profile ./package.sh
#
# The notary profile is one made with `xcrun notarytool store-credentials`
# (Apple ID, app-specific password, team) — made by the owner, never here.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VERSION="$(defaults read "$PWD/build/iTunes Remote.app/Contents/Info" CFBundleShortVersionString)"
DIST="build/dist"
STAGE="$DIST/iTunes Remote"
rm -rf "$DIST"
mkdir -p "$STAGE/Daemon"
cp -R "build/iTunes Remote.app" "$STAGE/"
rsync -a --exclude __pycache__ --exclude tests --exclude bin --exclude tools --exclude probe_ipod.sh --exclude setup.sh ../daemon/ "$STAGE/Daemon/"
chmod +x "$STAGE/Daemon/Install iTunes Remote Daemon.command"
cat > "$STAGE/Read Me.txt" <<TXT
iTunes Remote $VERSION

Two Macs: one that runs iTunes 12 (the library, the iPod, the speakers) and
one you sit at.

1. On the iTunes Mac: copy the Daemon folder anywhere (Applications is fine)
   and double-click "Install iTunes Remote Daemon.command". It asks for
   Python from python.org if that is missing, starts the daemon so it comes
   back at every login, and prints a six-digit pairing code.

2. On this Mac: drag iTunes Remote to Applications and open it. It finds
   the other Mac on the network and asks for the code. That is the remote.

3. Optional, on the way through setup: Tailscale on both Macs makes it work
   away from home; Ollama on this Mac turns on the Playlist Curator.

Everything stays on your own machines. Nothing is sent anywhere else.
TXT
DMG="$DIST/iTunes Remote $VERSION.dmg"
hdiutil create -volname "iTunes Remote" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
if [ -n "${ITR_SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp -s "$ITR_SIGN_IDENTITY" "$DMG"
fi
if [ -n "${ITR_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$ITR_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "notarized and stapled"
fi
echo "packaged $DMG ($(du -h "$DMG" | cut -f1))"
