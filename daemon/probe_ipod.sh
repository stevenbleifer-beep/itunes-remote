#!/bin/bash
# Milestone 9 gate. Plug the iPod in, confirm iTunes shows it, then run this
# on the MacBook Pro. If it prints "OK, sync started", sync can be built.
# If it prints FAILED, per SPEC section 7, sync stays out of the app.
cd "$(dirname "$0")"
if mount | grep -q " /Volumes/iPod "; then
    echo "WARNING: /Volumes/iPod is mounted in disk mode; iTunes may hang. Eject it first." >&2
fi
osascript scripts/ipod_probe.applescript
