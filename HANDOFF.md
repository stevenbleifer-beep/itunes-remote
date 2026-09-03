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
| Recently Added | Added 2026-09-03. A source under LIBRARY with a clock icon, showing the 600 newest tracks and their albums, newest first, in whichever view is selected. The daemon does the ordering: `recent=N` on `/api/tracks` and `/api/albumlist`, where an album's recency is its newest track's. There is also a Date Added column. |
| iTunes alerts | Added 2026-09-03. `GET /api/itunes/alert` reads any modal dialog iTunes is showing and `POST /api/itunes/alert/dismiss` clicks one of its buttons. Needs Accessibility for the agent's Python; without it the System Events call *hangs* rather than failing, so one bad result disables the check for the life of the process. `?recheck=1` re-arms it. This is how the sync warning dialog was found. |
| 8 Polish | Done: legacy scrollers, toned button, sidebar icons and dark selection, DEVICES section, View/Search captions, title, bottom-bar buttons (add, shuffle, repeat, artwork toggle, sync, eject), checkbox column, Cover Flow scrubber arrows, Apple's AirPlay symbol. Not done: a drawn capsule search field (the small-size system field was accepted); square bezels on sheet text fields. |
| Device page | Added 2026-09-03. Picking a device in the source list replaces the browser and track table with an iTunes 10 device page: Summary / Music / Playlists tabs, the identity panel, the segmented capacity bar with its legend, and Sync and Eject. `GET /api/devices` merges iTunes' own sources with the Apple devices on the USB bus, so an iPhone or iPad iTunes has not opened as a source still gets a row and a page that says why it is empty rather than silently not appearing. `GET /api/devices/{name}` adds the per-category item counts and byte totals, and the device's playlists. The chosen tab persists in `defaults` under `deviceTab`. |
| Drag and drop | Added 2026-09-03. Tracks drag out of the track table onto a playlist or onto the iPod in the source list. Dropping on a playlist works. Dropping on the device asks iTunes to `duplicate` the tracks onto it, which iTunes allows **only** when the device is set to "Manually manage music and videos"; otherwise every copy fails with -54 (File permission error) and the app says which setting is in the way instead of showing the raw error. Verified against the real iPod: it is set to sync selected playlists, so it refuses, and the explanation is what appears. |
| Artwork cache | Added 2026-09-03. Covers exported from iTunes are written to `~/Library/Caches/iTunesRemote/artwork`, so each one costs its 0.3 s AppleScript export once ever rather than once per daemon run. A miss is recorded too, but only after iTunes has actually answered. Freshness is the track's Date Modified. A background warmer fills the cache one cover at a time, and only after `artwork_warm_idle` seconds with no request, so it never competes with someone using the app. |
| Browser grouping | Corrected 2026-09-03 against iTunes' own column browser. See "iTunes browser grouping" below. |
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

## iTunes browser grouping, measured not guessed

iTunes 12.9.5's column browser on this library reports 76 genres, 2,909
artists and 9,214 albums. Reproducing those numbers took four rules, each
checked by dumping the live Music playlist through AppleScript and counting in
Python:

1. Only the Music library counts. Podcasts, movies and TV shows are excluded.
2. A track files under its **album artist**, and anything flagged as a
   compilation gathers under one **Compilations** row.
3. Artists group by the **Sort Artist / Sort Album Artist** field where the
   track has one, so "JAY Z" and "Jay-Z" share a row. **Albums do not**: Sort
   Album is usually just the title with its article stripped, and grouping on
   it merges genuinely different albums (9,203 against the real 9,214).
4. Grouping is accent- and punctuation-insensitive — "Motorhead" and
   "Motörhead" are one row — and a blank tag gets no row and is not counted.

Result: genres 76 exactly, artists 2,905, albums 9,213. The residue is the
52-track difference between the daemon's audio filter and iTunes' Music
playlist, not the rule. `browse_key` in `library.py` is the grouping key;
`_filter` matches on the same key so a browser click selects exactly the rows
it counted.

## Traps found, all verified

- AppleScript `id` of a track is not the XML Track ID (that is `database ID`). Look up by `persistent ID`: 0.2 s standalone, 75 ms batched. `whose persistent ID is in {...}` fails with -10014.
- `st` is a reserved word in iTunes' dictionary, as are `missing` and `removed`.
- `play <track>` makes a one-item queue, so iTunes' own `next track` stops playback. The client steps through the visible list instead.
- `get name of current AirPlay devices` errors; iterate `AirPlay devices` and read `selected`.
- `add` re-imports a track already in the library; use `duplicate t to pl`. `delete` from a `user playlist` only removes membership.
- CPython empties a list during `list.sort`; never sort a list readers iterate. `patch_many` rebinds a `sorted()` copy.
- An autoresizing NSView never receives `layout()`; hook `setFrameSize`.
- `URL.appendingPathComponent` does **not** re-encode a `%`, so a path
  component escaped before it is passed in comes out double-encoded:
  `iPod classic` became `iPod%2520classic` and the daemon answered 404. Pass
  device names raw. This had silently broken the client's Sync and Eject
  buttons for the whole life of the feature; the daemon endpoint was fine.
- `whose special kind is "Music"` fails with -1728 on a device source. Iterate
  the playlists and read `special kind` instead.
- Summing `size of every track` for a 23,000-track device by looping the
  AppleScript list takes 21 s (the O(n^2) index trap). Join the list with a
  text item delimiter and add the numbers in Python: 1.1 s.
- `NSSplitView.setPosition` does nothing before the window is on screen, which
  left the column browser collapsed on every launch in List view. Apply it in
  a `DispatchQueue.main.async` after the first layout pass.
- `name of tracks 1 thru n of pl` is the plural form iTunes answers in one
  event. Binding that range to a variable first yields a list of references,
  and `name of` that list fails with -1700.
- iTunes refuses `duplicate <track> to <device playlist>` with -54 unless the
  device is set to manual management. The file is fine; the setting is not.
- iTunes writes device sizes in binary units but labels them GB: a
  159,839,977,472-byte iPod reads as "148.87 GB" on its Summary pane, so the
  device page uses GiB there and decimal GB nowhere.
- `com.apple.iPod.plist` is the only place the printed serial number and the
  firmware version live. Its `Devices` dictionary is keyed by the same id the
  USB bus reports, and its `Family ID` names the picture in iTunes.app
  (`iPod11-Black.icns` for this iPod classic).
- `zPosition` is a real z coordinate under a perspective `sublayerTransform`; keep it tiny.
- A regular-size NSSearchField with an 11-point font sits its text low; use `.small`.
- An attributed `stringValue` ignores the field's `alignment`; put the paragraph style in the attributes.
- Whitespace-only tags (an album artist of " ") must count as blank or they become phantom artists.
- The XML's `Application Version` is the build string (12.9.5.5); the marketing version comes from iTunes' Info.plist.
- **`set enabled of <track>` is silently ignored by iTunes 12.9.5.** It returns without error and the value does not change, on the library playlist and on a user playlist alike, and no track in this library carries `Disabled` in the XML. The checkbox column reads the state but verifies every write and tells the user when it did not stick. Every other editable field (genre, name, artist, album, year, track and disc number, compilation, rating) writes correctly.
- `NSTableView.drawGrid(inClipRect:)` must be overridden to skip group rows, or column dividers slice through album headers.
- An `ArtworkView` used as a small thumbnail needs `fillsBounds`, or it reserves room for a caption and the cover renders too small.
- A cache of "already requested" indices must be cleared whenever the backing list is replaced, or every cell keeps its placeholder. This bit the Grid view when switching to Recently Added.
- Only `.list` view is driven by the track list; every other view is driven by the album list, so `onTracksChanged` has to refetch albums for all three of them.
- An iPod left mounted in disk mode has hung iTunes at launch before. It was mounted during the successful probe, so it is not fatal, but `check.py` flags it and `launch_itunes` refuses while it is mounted.

## Things Steven cares about

- Never write to library files directly. Every mutation goes through iTunes; he asked why and agreed.
- The iTunes 10 look, with the reference screenshot he supplied on 2026-09-03 as the target. He notices small things (glyph shape, placeholder alignment, version strings) and wants them right.
- Visual sign-off from screenshots sent with SendUserFile.
- Cover Flow "as much like iTunes 10 as possible with some modern niceties."
