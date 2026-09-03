#!/bin/bash
# Milestone 2 harness: compiles the gel button and its test window.
#   ./build-geltest.sh                 build
#   ./build-geltest.sh --snapshot X    build, then render the window to X (png)
#   ./build-geltest.sh --run           build, then open the window
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -o build/GelButtonTest \
    Sources/Aqua/AquaPushButton.swift \
    Tools/GelButtonTest/main.swift \
    -framework Cocoa
case "${1:-}" in
    --snapshot) ./build/GelButtonTest --snapshot "$2" ;;
    --run) ./build/GelButtonTest & ;;
esac
