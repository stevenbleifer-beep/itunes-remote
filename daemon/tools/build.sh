#!/bin/bash
# Builds the helper tools the daemon uses when it drives Music.app rather
# than iTunes. Output goes to daemon/bin/, which is not tracked.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p bin
swiftc -O -o bin/musiclibdump tools/musiclibdump/main.swift -framework iTunesLibrary
codesign --force -s - bin/musiclibdump >/dev/null 2>&1 || true
echo "built bin/musiclibdump"
