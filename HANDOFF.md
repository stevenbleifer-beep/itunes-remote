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

## Sync plan: iTunes' own rules

The app holds its own sync selection (`daemon/itunes_remote/syncplan.py`,
keyed by device serial) and writes it into a playlist the iPod syncs. It is
built the way iTunes' Music pane is built and nothing cleverer:

- The four lists — Playlists, Artists, Genres, Albums — each stand on their
  own. The device gets the **union** of every ticked row.
- Ticking an artist means that artist. It is **not** shorthand for that
  artist's albums, so unticking one album takes out that album alone and
  leaves the artist tick where it was.
- An earlier build expanded an artist tick into its albums so that unticking
  one album could carve a hole in it. That was removed on 2026-09-03 at
  Steven's request ("just do it how itunes does it"). `_albums_of` and
  `_artist_states` went with it; `POST /api/sync/toggle` now records exactly
  the row it was given.
- The plan's own playlist never appears in the Playlists list — it is the
  plan's output, not one of its sources.
- Apply (`POST /api/sync/rebuild`) is the only call that touches iTunes. It
  rewrites that one playlist, in 150-selection chunks, and nothing else.

`--snapshot-device NAME` on the client opens that device's Music pane before
capturing, which is how this pane gets checked.

## The copy Steven actually runs is /Applications/iTunes Remote.app

`./build.sh` alone only updates `client/build/`. Steven launches
`/Applications/iTunes Remote.app`, so nothing reaches him until
`./build.sh --install` (which quits the running copy, rsyncs the bundle in
place and relaunch is a plain `open`). A whole evening of fixes was reported
"still broken" because they had only been built, not installed. Always end a
client change with `--install`.

## Debug pass, 2026-09-03 evening

What was found and fixed, in the order Steven listed them:

- **Shuffle/repeat off while playing on the Air.** `LocalPlayer.state` hard-coded
  shuffle false / repeat off, and the window read them from there. Shuffle and
  repeat are now `PlayerController`'s own, persisted in defaults, laid over the
  live state in both modes; iTunes is only told about them as a courtesy.
- **Local volume snapped to 75%.** Now 100% on every switch to this Mac, at Steven's request.
- **Recently Added.** `recent` was applied *after* the browser filters and was
  ignored by the facet endpoints entirely, so the Artists pane listed all
  2,904 artists and an album picked from the newest 600 *albums* could have
  none of its tracks in the newest 600 *tracks* (Miles Davis — Milestones was
  the one that showed it). `_candidates(playlist, recent)` now cuts to the
  newest N first, and tracks, facets and albums all start from that set.
- **Recently Added order.** With no column sort it is newest album first,
  each album's songs in disc/track order, instead of plain date order (which
  scrambled a rip's sides). Album views always show an album in track order.
- **Sorting.** Compact rows carry `sortArtist`/`sortAlbum`/`sortName`
  (iTunes' sort forms: Sort field, else article dropped, quotes and other
  punctuation ignored, accents dropped, names starting with a digit after Z —
  `sort_form` in library.py, which the browser panes and album lists use too). The client
  sorts on those, so Artist matches the default order (artist → year → album →
  disc → track), Album is album → artist → disc → track, and every other
  column falls back to artist order. Descending reverses the lot.
- **Speed.** Whole-library reads are gzipped (27 MB → 5.9 MB) and cached in
  `APIClient` until the daemon's library version changes or the app writes;
  going back to a source is instant. `LibraryController` polls
  `/api/library` every 15 s and reloads only when the track or playlist count
  changes.
- **Sync count.** iTunes says 24,045, the device 24,014, the 37 ticked
  playlists reference 24,173 distinct tracks. 159 of the gap are *duplicate
  copies* of the same song (21 share a file, 102 are distinct files of
  identical size — re-downloaded purchases) that iTunes syncs once; 2 are on
  the device but in no playlist; only 2 files are genuinely absent (Mötley
  Crüe "Shout At The Devil" from Guitar Hero II, and Gorillaz "Désolé";
  both files exist and read fine with afinfo, so iTunes refused them for
  its own reasons). Every device playlist count equals its library count.
  The plan now ticks the same 36 playlists iTunes does, plus the 348 artists;
  the pane heading shows the plan's distinct-track count (`status.trackCount`).
- **Mini player** menu item shows a tick while it is up (`validateMenuItem`).
- **Rating** works end to end (writes.log shows Steven's own 20→40→60 edits).
- **Bold row** stuck to old songs because nothing redrew the rows when the
  playing track changed; `updatePlayerUI` now reloads exactly the two rows.
- **Rewind** restarts the song after 3 s, and goes back a track before that.
- **HomePod.** The AirPlay menu *added* the pick to the set, so iTunes reported
  Computer + HomePod and kept playing through Computer. Plain click now
  routes to that one speaker (`selectOnly`), ⌘-click adds. Verified via the
  API: a HomePod alone selects cleanly, no dialog.
- **New Playlist.** The "+" works — the sheet appears. What failed was the
  reply: a fresh playlist has `"playlistId": null` until the XML catches up,
  and the client's `Playlist.playlistId` was `Int`, so the sheet showed
  "the data couldn't be read", *and every playlist list after that failed to
  decode* until iTunes rewrote the XML — which is also the likeliest reason
  drops onto playlists looked dead. Now `Int?`. Return in the field creates;
  Escape cancels.
- **Drag.** Album headers in Album List, and covers in Grid and Cover Flow,
  are drag sources now (ids newline-joined in one pasteboard item).
- **Buttons are buttons.** The drawn bevel and push buttons accept first mouse
  and expose an AX button role with a press action.
- **Media keys.** Not reproducible from here. The handlers now `NSLog`
  "media key: …" on arrival, so `log stream --predicate 'process == "iTunesRemote"'`
  tells whether the key reached the app at all.

Testing note: background (app_*) clicks never reach custom views on an
inactive window — the first click only activates. Real on-screen clicks were
used for the sheet test; Steven works in Safari on the other display, so
screen takeovers were kept to a minimum.

## Sync progress on the LCD (2026-09-03, late)

iTunes 10 stacked a pair of small ▲▼ arrows on the display when it had more
than one thing to show and clicking them cycled the views. `AquaDisplayPanel`
now has `Mode` (`.player`, `.sync`), `modes` (the arrows appear only when
there is more than one), and a sync view: title, detail line, and a bar that
is determinate for a plan rebuild (chunks done of total) and a barber pole
for an iPod sync (iTunes gives no total).

- Daemon: `sync_progress` under `progress_lock`; `GET /api/sync/progress`
  → `{active, kind: rebuild|ipod_sync, label, done, total, tracks, startedAt}`
  or `{active: false, endedAt, kind, label, tracks, error}`. `post_sync_rebuild`
  updates it per chunk. `post_source_sync` starts it and a watcher thread reads
  the device's song count every 8 s, calling the sync over once the count has
  held still for four reads (SPEC §7's "no progress bar" is superseded by
  Steven's request; the count is the only signal iTunes gives).
- Client: `PlayerController.watchSync()` (called by Apply and Sync) polls
  once a second while active and for 5 s after; otherwise every 10 s so a
  sync started elsewhere still shows. `MainWindowController.showSyncProgress`
  flips the display to `.sync` when a job starts, and 5 s after it ends drops
  the view unless the arrows were used by hand meanwhile (`syncViewPinned`).
- Verified end to end: Apply on the Music pane → LCD reads "Writing the sync
  playlist for “iPod classic”… 0 of 384 selections" with the arrows; the
  arrows switch to Now Playing and back while the rebuild runs; the daemon
  reported `active: true, done/total` throughout; writes.log shows the
  rebuild finishing (25,875 tracks).
- The drawn buttons and the display accept first mouse and expose AX roles,
  so the background app_* tools can press them now ("New Playlist",
  "Shuffle", "Sync iPod" show up as AXButtons).

## Artwork: why the Grid was slow, and what changed

A cover the daemon has on disk or embedded in the file costs ~30 ms. A cover
only iTunes knows about costs an AppleScript export — about 0.3 s, holding the
one Apple Events lock the whole daemon shares — and the client asked for those
on the *same* URLSession as the player poll, with a 30 s timeout. A screenful
of albums whose covers were not yet cached therefore filled the connection
pool with slow exports, and every other cover (and the poll) queued behind
them. Hence a grid of grey placeholders that filled in over many seconds.

Now:
- `GET /api/tracks/{id}/artwork?quick=1` answers only from memory, the disk
  cache, or the file itself. A cover needing iTunes returns **202** and is
  pushed onto `artwork_priority`, which the warmer drains *before* its own
  sweep and without waiting for the idle window.
- The client fetches covers on a separate URLSession (12 connections, 20 s),
  so covers never contend with the player poll. A 202 is retried at a widening
  interval for about a minute.
- Grid and Cover Flow skip albums iTunes says have no art at all
  (`hasArtwork`), instead of paying a round trip to be told so.
- The warmer's sweep is rebuilt every 10 minutes rather than once, so covers
  for newly added music get picked up without a daemon restart.

Measured after: the 14 albums at the top of the library return in 0.77 s total.

## Ejecting the iPod

There is an Eject button in the bottom bar and one on the device page's
header; both call `POST /api/sources/{name}/eject`, which is iTunes' own
`eject`. It fails with **"in use by another application"** when anything on
the MacBook Pro still has a file open on `/Volumes/iPod` — and this daemon was
one of those things:

- the device page refreshes every 15 s (`device_info` against the iPod),
- the source list every 30 s,
- `_connected_pod` for the sync plan,
- and, since the LCD work, `_watch_ipod_sync` polling the song count every 8 s
  for up to four hours after a sync.

So an eject now sets `device_quiet_until` for 30 s: `_connected_pod` returns
None, `get_device` answers 409, and the sync watcher stops. The client pauses
both of its device timers before asking and resumes them if the eject fails.
A failure also reads back whatever dialog iTunes is showing and includes it.

`lsof /Volumes/iPod` on the MacBook Pro is the way to see what is holding it.
Expect iTunes itself to hold `iPod_Control/iTunes/iTunesControl` — that is
normal and iTunes releases it. A `diskutil unmount` "dissented by PID …
SystemUIServer" means the menu bar agent is refusing; that one is not ours.

## The machines

- MacBook Pro (daemon host): `ssh -i ~/.ssh/id_ed25519_mbp2012 stevenbleifer@Stevens-MacBook-Pro.local`. Python 3.13.15 at `/usr/local/bin/python3`. iTunes 12.9.5.
- Daemon at `~/iTunesRemote/daemon` on the MBP, deployed with
  `rsync -a -e "ssh -i ~/.ssh/id_ed25519_mbp2012" --exclude __pycache__ --exclude tests daemon/ stevenbleifer@Stevens-MacBook-Pro.local:~/iTunesRemote/daemon/`.
  Config `~/Library/Application Support/iTunesRemote/config.json` (which holds the bearer token — read it from there, never paste it into a tracked file), port 8765. Logs in `~/Library/Logs/iTunesRemote/` (`daemon.log`, `writes.log`).
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

## The sync selection: what is and is not reachable, tested 2026-09-03

iTunes' sync selection (which playlists/artists/albums/genres go to a device)
cannot be read or written from outside iTunes. All three routes were tested,
not assumed:

1. **AppleScript** — the dictionary has no terms for sync settings at all. It
   can *start* a sync (`update`) but exposes no property for the selection.
2. **Accessibility** — iTunes 12.9.5's window reports **0 UI elements**, both
   cold and after forcing `AXEnhancedUserInterface` (which is a real, settable
   attribute — setting it succeeded and changed nothing). There is no element
   to read or click.
3. **The library database** — the selection lives in the binary, undocumented
   `iTunes Library.itl`. Readable preference plists hold only trivia.

Screen control *does* work but was rejected as too unreliable: after
`activate` + `AXRaise` the window composites and `screencapture` shows the real
checkboxes, and a synthetic `CGEvent` click toggled "The Beatles" successfully
(then restored it). It needs the window raised, and blind coordinates break the
moment a list scrolls — and a wrong click silently removes music at the next
sync. Steven's own spec forbids it (SPEC.md:183) and that stands.

**The way round it: own the selection instead of reading it.** Playlist
membership *is* fully scriptable and fast. Measured:

- a whole playlist's tracks cross in **one** event: 491 tracks in ~1 s
- `duplicate (every track of lib whose artist is "X") to pl` — one event, ~0 s
- `delete (every track of pl whose genre is "X")` — one event, ~0 s

So `scripts/sync_rebuild.applescript` projects an app-held selection onto one
app-owned playlist ("iPod Sync (Remote)"). Verified: a spec of one artist, one
genre and one playlist built 447 tracks in ~1 s, was idempotent on a second
run, and the contents matched exactly (Adele 79, Comedy 316, Bedroom Pop 52).

This needs **one manual step, once**: in iTunes, set the iPod's Music pane to
"Selected playlists…" and tick only that playlist. After that the app is the
sole authority over what syncs and its checkboxes can be real controls.
Not yet wired to the UI.

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
