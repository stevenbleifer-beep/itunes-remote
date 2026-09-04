#!/bin/bash
# Double-click this on the Mac that runs iTunes. It puts the daemon in place,
# starts it as a LaunchAgent that comes back at every login, and prints the
# pairing code the iTunes Remote app asks for.
#
# Run it again any time: it reinstalls the daemon files, keeps the existing
# token and pairing code, and prints the code again.
set -u

LABEL="local.itunesremote.daemon"
OLD_LABEL="local.stevenbleifer.itunesremote"
SUPPORT="$HOME/Library/Application Support/iTunesRemote"
DEST="$SUPPORT/daemon"
CONFIG="$SUPPORT/config.json"
LOG_DIR="$HOME/Library/Logs/iTunesRemote"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SRC="$(cd "$(dirname "$0")" && pwd)"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31m%s\033[0m\n' "$*"; echo; echo "Press Return to close."; read -r; exit 1; }

echo
bold "iTunes Remote — daemon installer"
echo

# 1. iTunes itself.
if [ ! -d /Applications/iTunes.app ]; then
    fail "iTunes is not in /Applications. This daemon drives iTunes 12 (macOS Mojave or earlier); on newer macOS the Music app is not supported yet."
fi
ITUNES_VERSION="$(defaults read /Applications/iTunes.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo "?")"
echo "iTunes $ITUNES_VERSION found."

# 2. Python 3.9 or newer. Mojave ships none, so the python.org installer is
#    the way; it supports 10.9 and up and takes a minute.
PYTHON=""
for candidate in /usr/local/bin/python3 /Library/Frameworks/Python.framework/Versions/3.*/bin/python3 /opt/homebrew/bin/python3; do
    if [ -x "$candidate" ] && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
        PYTHON="$candidate"
        break
    fi
done
if [ -z "$PYTHON" ]; then
    echo
    bold "Python 3 is needed and is not installed."
    echo "Opening the python.org download page. Install the latest 3.x for macOS"
    echo "(the 'macOS 64-bit universal2 installer'), then double-click this installer again."
    open "https://www.python.org/downloads/macos/"
    echo; echo "Press Return to close."; read -r
    exit 1
fi
echo "Python: $PYTHON ($("$PYTHON" -c 'import platform; print(platform.python_version())'))"

# 3. The library file the daemon reads.
XML="$HOME/Music/iTunes/iTunes Music Library.xml"
if [ ! -f "$XML" ]; then
    echo
    bold "iTunes is not sharing its library XML."
    echo "In iTunes: Preferences > Advanced > tick 'Share iTunes Library XML with other applications', then run this again."
    echo; echo "Press Return to close."; read -r
    exit 1
fi
echo "Library: $XML ($(du -h "$XML" | cut -f1))"

# 4. Copy the daemon into place and write the config.
mkdir -p "$DEST" "$LOG_DIR" "$HOME/Library/LaunchAgents"
rsync -a --delete --exclude __pycache__ --exclude tests "$SRC/itunes_remote" "$SRC/scripts" "$SRC/check.py" "$DEST/" 2>/dev/null \
    || { rm -rf "$DEST/itunes_remote" "$DEST/scripts"; cp -R "$SRC/itunes_remote" "$SRC/scripts" "$SRC/check.py" "$DEST/"; }
if [ ! -f "$CONFIG" ]; then
    (cd "$DEST" && "$PYTHON" -m itunes_remote --init-config) >/dev/null || fail "Could not write $CONFIG"
    echo "Wrote a new config with a fresh token."
else
    echo "Keeping the existing config (token and pairing code unchanged)."
fi

# 5. The LaunchAgent. An agent, not a daemon: Apple Events need the logged-in
#    session, and a LaunchDaemon runs before login and cannot reach iTunes.
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>-m</string>
        <string>itunes_remote</string>
    </array>
    <key>WorkingDirectory</key><string>$DEST</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>$LOG_DIR/launchagent.out</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/launchagent.err</string>
    <key>EnvironmentVariables</key>
    <dict><key>PYTHONUNBUFFERED</key><string>1</string></dict>
</dict>
</plist>
PLIST

UID_NUM="$(id -u)"
# An older install under the development label gives way to this one.
launchctl bootout "gui/$UID_NUM/$OLD_LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
# bootout returns before the job is gone; a bootstrap that lands too soon
# fails with "Input/output error" and leaves nothing loaded.
for i in $(seq 1 20); do
    launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || break
    sleep 0.5
done
LOADED=""
for i in 1 2 3 4 5; do
    if launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null; then LOADED=1; break; fi
    sleep 2
done
[ -n "$LOADED" ] || launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || fail "launchctl could not load the agent."
launchctl kickstart -k "gui/$UID_NUM/$LABEL"
echo "Daemon started (it reads the whole library first; a big one takes half a minute)."

# 6. Wait for it, then make it talk to iTunes once, so macOS asks *now*,
#    while someone is at the screen, whether Python may control iTunes.
PORT="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("port", 8765))' "$CONFIG")"
TOKEN="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$CONFIG")"
CODE="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["pairing_code"])' "$CONFIG")"
for i in $(seq 1 60); do
    if curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/api/hello"; then break; fi
    sleep 2
done
echo
bold "If macOS asks whether \"Python\" may control \"iTunes\", click OK."
curl -s -m 30 -o /dev/null -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/api/player" || true
sleep 2

# 7. Report.
echo
(cd "$DEST" && "$PYTHON" check.py 2>/dev/null) | grep -E "^(PASS|FAIL)" | sed 's/^/  /' || true
echo
bold "Pairing code:  $CODE"
echo
echo "On the Mac you will use as the remote, open iTunes Remote. It finds this Mac"
echo "(\"$(scutil --get ComputerName)\") on the network by itself and asks for that code."
echo
echo "Optional, so the app can show and dismiss iTunes' own alert dialogs from afar:"
echo "  System Preferences > Security & Privacy > Privacy > Accessibility"
echo "  click the lock, then +, press Command-Shift-G and paste:"
echo "    $("$PYTHON" -c 'import os, sys; print(os.path.dirname(os.path.dirname(os.path.realpath(sys.executable))) + "/Resources/Python.app")')"
echo
echo "Logs: $LOG_DIR    Reinstall or reprint the code: run this file again."
echo
echo "Press Return to close."
read -r
