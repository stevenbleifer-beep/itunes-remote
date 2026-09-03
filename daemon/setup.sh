#!/bin/bash
# Installs the daemon as a LaunchAgent on the MacBook Pro. Run it there:
#
#   cd ~/iTunesRemote/daemon && ./setup.sh
#
# A LaunchAgent, not a LaunchDaemon: Apple Events need the logged-in GUI
# session, and a LaunchDaemon runs before login and cannot reach iTunes.
#
# First run, over Screen Sharing: macOS will ask whether "Python" may control
# "iTunes". Approve it. Approving from a Terminal run would grant Terminal,
# not the LaunchAgent's Python, so let the agent itself trigger the prompt.
set -euo pipefail

LABEL="local.stevenbleifer.itunesremote"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PYTHON="/usr/local/bin/python3"
DAEMON_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$HOME/Library/Logs/iTunesRemote"
CONFIG="$HOME/Library/Application Support/iTunesRemote/config.json"

if [ ! -x "$PYTHON" ]; then
    echo "FAIL: $PYTHON not found. Install Python 3.13 from python.org (the last release for Mojave)." >&2
    exit 1
fi
mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

if [ ! -f "$CONFIG" ]; then
    echo "No config yet; creating one with a fresh token."
    (cd "$DAEMON_DIR" && "$PYTHON" -m itunes_remote --init-config)
fi

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
    <key>WorkingDirectory</key><string>$DAEMON_DIR</string>
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
echo "wrote $PLIST"

# Stop any hand-started copy so the port is free for the agent.
pkill -f "itunes_remote$" 2>/dev/null || true

UID_NUM="$(id -u)"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl kickstart -k "gui/$UID_NUM/$LABEL"
echo "agent loaded: $LABEL"
echo
echo "If a dialog asks whether Python may control iTunes, click OK. Then:"
echo "  System Preferences > Security & Privacy > Privacy > Automation: Python -> iTunes should be ticked."
echo
sleep 3
(cd "$DAEMON_DIR" && "$PYTHON" check.py) || true
