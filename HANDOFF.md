# Handoff, 2026-09-03

Read SPEC.md first; it is the authority and carries dated revision notes.
This file is the state of play and the traps that are not in the spec.

## Where things stand

| Milestone | State |
|---|---|
| 1 Daemon read path | Done. 23 s to parse the real XML on the MacBook Pro, reads under 50 ms, full library in 1.15 s / 13.6 MB. |
| 2 Push button | Done, signed off. Toned to the Snow Leopard look during polish. |
| 3 Read-only client | Done, accepted. iTunes 10 look. |
| 4 Playback, AirPlay, artwork | Done, verified end to end at low volume. |
| 5 Single-track write | Done. Verified from iTunes' own side, with revert. |
| 6 Bulk genre edit | Done. 300 of 300 updated and reverted; 52 s for 300 (173 ms/track, mostly iTunes rewriting file tags). |
| 7 Playlists | Done. Create, add, remove; verified in iTunes. |
| 7a Cover Flow | Done. All four iTunes 10 views: List, Album List, Grid, Cover Flow. Plus a mini player (Command-Shift-M) with transport, volume, AirPlay and the display, and an app icon drawn by `Tools/MakeIcon`. |
| 8 Polish | Done: legacy scrollers, toned button, sidebar icons and dark selection, DEVICES section, View/Search captions, title, bottom-bar buttons (add, shuffle, repeat, artwork toggle, sync, eject), checkbox column, Cover Flow scrubber arrows, Apple's AirPlay symbol. Not done: a drawn capsule search field (the small-size system field was accepted); square bezels on sheet text fields. |
| 9 iPod sync | Verified 2026-09-03: `update` on "iPod classic" returned "sync started", and afterwards 160 files had been written under `/Volumes/iPod/iPod_Control` with fresh MP3s at 23:26, so the sync engine really ran. Built: DEVICES row with free space, Sync and Eject buttons, `/api/sources`, `/api/sources/{name}/sync` and `/eject`. Eject is untested because it would have disconnected the iPod. iTunes logs a harmless read-only `com.apple.iPod` prefs warning on that machine. |
| Play on This Mac | Added 2026-09-03 at Steven's request. iTunes 12.9.5 cannot AirPlay to a current Mac (error -15022; iTunes shows "not compatible with the current AirPlay playback configuration"), so `GET /api/tracks/{id}/audio` streams the file with range support and the client plays it with AVFoundation. Transport, seek, volume and auto-advance drive the local player in that mode; picking any AirPlay device switches back and stops local playback. Verified headless: ready in ~2 s, seeks land within a second. |
| SPEC section 9 deployment | Done. Steven ran `setup.sh` on 2026-09-02 23:40; the LaunchAgent is loaded and Automation is approved for the agent's Python. `check.py` passes everything except "No iPod volume mounted" while the iPod is attached, which is informational. |

Git: everything is committed on the default branch; `git log --oneline`.

## The machines

- MacBook Pro (daemon host): `ssh -i ~/.ssh/id_ed25519_mbp2012 stevenbleifer@Stevens-MacBook-Pro.local`. Python 3.13.15 at `/usr/local/bin/python3`. iTunes 12.9.5.
- Daemon at `~/iTunesRemote/daemon` on the MBP, deployed with
  `rsync -a -e "ssh -i ~/.ssh/id_ed25519_mbp2012" --exclude __pycache__ --exclude tests daemon/ stevenbleifer@Stevens-MacBook-Pro.local:~/iTunesRemote/daemon/`.
  Config `~/Library/Application Support/iTunesRemote/config.json`, token `<the token is in config.json on the MacBook Pro>`, port 8765. Logs in `~/Library/Logs/iTunesRemote/` (`daemon.log`, `writes.log`).
- **The daemon is a LaunchAgent now. Never start it by hand.** After an rsync, restart it with
  `ssh ... 'launchctl kickstart -k gui/$(id -u)/local.stevenbleifer.itunesremote'`
  About 25 s to come up. A hand-started copy steals the port and the agent then crash-loops every 10 s on "address already in use" (this happened once). AppleScript files are read per call, so script-only changes need no restart.
- Use IPv4 `http://<lan-ip>:8765`; the `.local` name's IPv6 address hangs curl with short timeouts.
- Client, from `client/`: `./build.sh`, then
  `"build/iTunes Remote.app/Contents/MacOS/iTunesRemote" --host <lan-ip> --token <token>` (`--flow-index N` opens Cover Flow at album N).
  Screenshot: `W=$(./build/windowid "iTunes Remote" | head -1 | cut -d' ' -f1); screencapture -x -o -l $W out.png`.
  View mode persists in `defaults` under `local.stevenbleifer.itunesremote viewMode` (0 list, 1 Cover Flow); the artwork pane under `artworkPane`.
- Harnesses: `client/build-geltest.sh`; `client/build/InfoPanelTest --snapshot x.png [--multi]`, built with
  `swiftc -O -o build/InfoPanelTest Sources/Aqua/*.swift Sources/API/*.swift Sources/App/InfoPanel.swift Tools/InfoPanelTest/main.swift -framework Cocoa`.
- Tests: from `daemon/`, `python3 -m unittest discover` (11 tests, pass on both machines).

## What to do next, in order

1. Exercise in the live app what was only verified through the daemon: the Get Info sheet, Add to Playlist and Remove from Playlist, the checkbox column, shuffle and repeat, Eject.
2. Nothing outstanding from the references: all four views, the mini player and the icon are built. Ideas left: a drawn capsule search field, square bezels on sheet text fields, and the Genius / Ping panes, which have no offline equivalent and were deliberately skipped.
3. Cover Flow artwork at scale. Only 61.7% of tracks have embedded art; the rest fall through to an AppleScript export under the global Apple Events lock (about 0.3 s each). It works, with a 300-entry daemon cache and a 400-entry client cache, but flying fast through thousands of albums queues behind that lock and slows the player poll.

## Traps found, all verified

- AppleScript `id` of a track is not the XML Track ID (that is `database ID`). Look up by `persistent ID`: 0.2 s standalone, 75 ms batched. `whose persistent ID is in {...}` fails with -10014.
- `st` is a reserved word in iTunes' dictionary, as are `missing` and `removed`.
- `play <track>` makes a one-item queue, so iTunes' own `next track` stops playback. The client steps through the visible list instead.
- `get name of current AirPlay devices` errors; iterate `AirPlay devices` and read `selected`.
- `add` re-imports a track already in the library; use `duplicate t to pl`. `delete` from a `user playlist` only removes membership.
- CPython empties a list during `list.sort`; never sort a list readers iterate. `patch_many` rebinds a `sorted()` copy.
- An autoresizing NSView never receives `layout()`; hook `setFrameSize`.
- `zPosition` is a real z coordinate under a perspective `sublayerTransform`; keep it tiny.
- A regular-size NSSearchField with an 11-point font sits its text low; use `.small`.
- An attributed `stringValue` ignores the field's `alignment`; put the paragraph style in the attributes.
- Whitespace-only tags (an album artist of " ") must count as blank or they become phantom artists.
- The XML's `Application Version` is the build string (12.9.5.5); the marketing version comes from iTunes' Info.plist.
- **`set enabled of <track>` is silently ignored by iTunes 12.9.5.** It returns without error and the value does not change, on the library playlist and on a user playlist alike, and no track in this library carries `Disabled` in the XML. The checkbox column reads the state but verifies every write and tells the user when it did not stick. Every other editable field (genre, name, artist, album, year, track and disc number, compilation, rating) writes correctly.
- `NSTableView.drawGrid(inClipRect:)` must be overridden to skip group rows, or column dividers slice through album headers.
- An `ArtworkView` used as a small thumbnail needs `fillsBounds`, or it reserves room for a caption and the cover renders too small.
- An iPod left mounted in disk mode has hung iTunes at launch before. It was mounted during the successful probe, so it is not fatal, but `check.py` flags it and `launch_itunes` refuses while it is mounted.

## Things Steven cares about

- Never write to library files directly. Every mutation goes through iTunes; he asked why and agreed.
- The iTunes 10 look, with the reference screenshot he supplied on 2026-09-03 as the target. He notices small things (glyph shape, placeholder alignment, version strings) and wants them right.
- Visual sign-off from screenshots sent with SendUserFile.
- Cover Flow "as much like iTunes 10 as possible with some modern niceties."
