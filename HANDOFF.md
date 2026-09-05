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

## Evening pass, 2026-09-03 (second batch)

All client-side; the daemon is untouched. Each is its own commit.

- **Shift-select in the sidebar.** `sourceList.allowsMultipleSelection`,
  with `selectionIndexesForProposedSelection` keeping only playlist rows in
  a multiple selection. A multiple selection does not navigate. Delete and
  forward-delete act on whichever list has focus: playlists in the sidebar,
  songs (remove from playlist) in the track table. Both confirm and name
  what is going. The app still never deletes from the library.
- **Grid covers were fetched and thrown away.** Every cell asked twice; the
  second time the cache answered synchronously *inside `draw`*, and AppKit
  drops a `setNeedsDisplay` issued while drawing. Repaints are now
  coalesced onto the next run-loop turn (`scheduleRepaint`). Neither Grid
  nor Cover Flow cached a transient nil as "no cover" any more; both retry
  unless `ArtworkCache.isKnownMiss`. This was the real cause of "album art
  is slow" — it was invisible, not slow.
- **Sort indicator.** `AquaHeaderCell` draws its own triangle on the sorted
  column (AppKit only calls `drawSortIndicator` when an indicator image is
  set, which nothing did). Direction accounts for the flipped header view.
- **Restore Playlist Order** in the header context menu and View ▸ Clear
  Column Sort (⌥⌘0). Clears the descriptor and re-fetches, since a column
  sort reorders the array in memory and the original order is gone.
- **Playing-playlist marker.** A speaker replaces the note icon beside the
  source the current song came from. iTunes reports the playlist, except
  for the one-item queue `play <track>` makes, so every start goes through
  `startPlayback(_:playlist:)` which records `startedFromPlaylistId`.
- **Up Next** (`UpNextPanel.swift`). A real manual queue, `upNext: [Track]`,
  consumed by `step(by: 1)` before the list carries on. Play Next / Add to
  Up Next in the track context menu and a new Controls menu (⌥⌘N, ⌥⌘E,
  ⌥⌘U). In the panel: drag to reorder, Delete removes, Clear, double-click
  plays now and drops what was ahead. Below the queue is a read-only
  preview of the list's continuation, omitted under shuffle.
- **Search suggestions** (`SearchPopup.swift`). A non-activating child
  panel under the field showing top artists / albums / songs for the text,
  fetched across the whole library with `async let` on the facet, album
  list and track endpoints. Keyed on the text still matching the field,
  not on focus. ↑↓ Return Escape route through the key monitor while the
  field has focus; a click elsewhere dismisses. Picking an artist or album
  clears the search and narrows Music through the column browser; picking
  a song plays it.

Testing note: background `app_type` sets the field by AX and does **not**
fire `controlTextDidChange`; a real keystroke (e.g. Backspace) does. The
suggestion panel also has `hidesOnDeactivate`, so the app must be
frontmost to see it.

**Two traps for whoever builds next.** `./build.sh` lives in `client/`, not
`client/Sources` — from the wrong directory the "no such file" line scrolls
past and nothing is built. And `./build.sh --install` while the app is
running kills it without a crash report (the bundle is replaced under the
process); quit first, install, relaunch.

- **Play context** (later the same evening). Next/Previous used to find the
  playing song in the live `rows`; click away from the album you started
  and it was no longer there, so `step` fell through to `player.next()` —
  iTunes' own Next, whose queue is whatever playlist it was last told to
  play *inside*. `startPlayback(_:playlist:context:)` now snapshots the
  list into `playContext` when playback starts from a list (nil keeps it,
  for queued or searched songs); `step`, `playInContext`, `nextIndex(in:)`
  and the Up Next preview all walk that snapshot, and nothing hands a step
  to iTunes any more.

## Remote access (2026-09-03, late)

Tailscale. The Air runs the official app; the Pro (Mojave) runs the community
v1.76.3 build from stanwu/tailscale-macos-mojave as a LaunchDaemon, socket
`/var/run/tailscaled.socket`, operator `stevenbleifer`. The client's
`serverHost` default is `<pro-name>.<tailnet>.ts.net`; the daemon
already listened on all interfaces. Nothing in the daemon changed. Over the
tunnel from home: player 0.43 s, cover 0.08 s, audio 2.9 MB/s.

## Home or away (2026-09-03, late)

`ConnectionMonitor` probes the LAN name (`serverLANHost`, default
`Stevens-MacBook-Pro.local`, which at home resolves to the Thunderbolt
bridge <bridge-ip>) on start, on every NWPathMonitor change and every 45 s
with a 2 s timeout. Answer → `api.baseURL` = LAN and normal cadence; no
answer → the tunnel name (`serverHost`) and away cadence: player every 3 s,
library version every 60 s, devices every 90 s, alerts every 15 s. Clicks
are never slowed. The flash says "Home — …" / "Away — …" on each switch.
Testing tip: `defaults write … serverLANHost nowhere-invalid.local` forces
away; `lsof` on the Air does not show the tunnel sockets — check
`netstat -an | grep 8765` on the Pro for <air-tailscale-ip> instead.

## "No artwork" that was there all along (2026-09-03, late)

The XML's `Artwork Count` is a reliable yes, not a reliable no: iTunes omits
it for tracks whose picture is embedded in the file (or only in its own
artwork store). 29 of 40 sampled "no-art" albums had covers the daemon
could read in milliseconds; the client never asked because `hasArtwork`
said not to. `get_album_list` now runs `_reconcile_artwork_flags`: memory
or disk cache wins where it has spoken, otherwise the flag is True ("maybe")
so the client asks; and `_artwork(quick=True)` no longer refuses
count-zero tracks — it queues them for the warmer, and the export's answer
(cover or MISS) is cached on disk, so each track costs one export ever.
Note the warmer's background sweep yields whenever a request arrived in the
last 20 s, i.e. never while the app is open; the priority queue (202s) is
what fills the cache in practice.

Catalog covers for the genuinely artless: `scratchpad/art/{match,apply}.py`
on the Air — exact artist+title match against the iTunes Search API,
`set_art.applescript` sets on tracks with zero artworks. Apple rate-limits
the search hard (~50 albums in 10 min); run it on the residue only.

## Playlist Curator (2026-09-04)

A local model that builds playlists from the library and edits them on
request. New sidebar section CURATOR above PLAYLISTS; its page replaces the
browser and track table (the sidebar and player stay). Controls ▸ Playlist
Curator, ⇧⌘K.

**How it works** (`client/Sources/App/CuratorEngine.swift`): the model never
sees the library. Each turn: (1) *plan* — the request (or the feedback plus
the conversation) becomes JSON: mood, 8–12 search phrases, up to 12 artists,
things to avoid, length, a name; (2) *gather* — the phrases go through the
embedding index and the artists through the folded artist table, giving up
to 140 real songs, round-robin so nobody swamps it, the current list kept on
the table for feedback turns; (3) *choose* — the model picks by number from
that list, so it cannot name a song that is not here. Rules the model is told
and ignores are enforced in code: real numbers only, no repeats, two per
artist unless the request is about that artist, no holiday songs unless
asked, the planned length. Feedback re-plans, so "add some slow indie rock"
reaches artists that were not on the table before. **A feedback turn is an
edit, not a new list:** the model returns `remove` / `add` / `order` and the
code applies it to the current list — asked for a whole new list it rewrote
most of it, and asked for removals it named fifteen of twenty for "less
jazz", so removals are capped at a third of the list unless the feedback
says all/most/replace/start over. A number in the feedback ("keep it to
20") sets the length; without one, a swap keeps the length it had and
"add a couple more" may grow it. The plan step also flags `fresh: true`
when a message is a new request rather than feedback, which resets the
conversation. **Eras are enforced in code**: `yearRange(in:)` reads "90s",
"the eighties", "1994 to 1998" from the words (the model's `years` is only
a fallback); songs tagged outside the range never reach the candidate list,
songs with no year tag fill in behind the dated ones. **The count is exact**:
the rules cost the model a few picks, so the list is topped up from the
candidates it passed over ("rounds out the list" as the reason). Steven's
first try, "20 song playlist for a 90s road trip", came back with 17 songs
and a 2009 Wolfmother track before these two fixes.

**Models** (Ollama, on the Air, `http://127.0.0.1:11434`): picker
`qwen3.5:4b` (defaults key `curatorModel`), embeddings `embeddinggemma:300m`.
Measured on the M5 Air: 4B does a 3,900-token curate prompt in 17–29 s
(721 tok/s prompt, 30 tok/s output); `gemma4:12b` takes 55–60 s for the same
and picks no better, so it is not the default. A whole turn is two model
calls: about 25–50 s. For more taste at two minutes a turn:
`defaults write local.stevenbleifer.itunesremote curatorModel gemma4:12b`.

**Index** (`CuratorIndex.swift`): one 256-dim unit vector per song
(embeddinggemma's 768 truncated — it is trained for that), in
`~/Library/Application Support/iTunes Remote/curator/{index.json,vectors.bin}`,
built in the background the first time the page opens (~130 songs/s, about
12 minutes for 93k; progress at the top right of the page) and saved every
4,096 songs, so a quit resumes. Search is one `cblas_sgemv`. The curator
works before the index is done, on artist matching alone — but the library
is sorted by artist, so a part-built index only knows the A's and B's and
the picks show it.

**Saving** files the playlist in an iTunes folder named "Curator"
(`POST /api/playlists` with `"folder": "Curator"`; the daemon's
`playlist_create.applescript` makes the folder if needed with
`make new user playlist at folder playlist X`). Playlists now carry
`folder`/`parentId`; the sidebar shows folders with a disclosure triangle,
children indented, collapsed set in defaults `collapsedFolders`.

**Testing without the screen:** `client/build/iTunes\ Remote.app/Contents/MacOS/iTunesRemote --source curator --curate "make a playlist for date night" --curate "less jazz, keep it to 20" --curate-save "Date Night"`
prints each list, saves the last, then quits. Add `--stay` and it prints
its window number instead and stays up, for `screencapture -l N`. Do not
use `--snapshot` for this page: the offscreen capture drops the text of
the layer-backed AppKit views (labels, text view, table cells) even though
the live window is fine.

**Prototype:** `curator/curator.py` was the proof (artist-list-in-prompt
design, ~10 minutes a playlist on gemma4:12b). Superseded; kept for the
record.

## Plug and play (2026-09-04, afternoon)

**The daemon moved.** Steven's Pro now runs the daemon the way a stranger's
would: from `~/Library/Application Support/iTunesRemote/daemon/` under the
LaunchAgent label **`local.itunesremote.daemon`** (the old
`local.stevenbleifer.itunesremote` was booted out and its plist removed by
the installer). **New deploy recipe:**

    rsync -a -e "ssh -i ~/.ssh/id_ed25519_mbp2012" --exclude __pycache__ --exclude tests \
        daemon/ "stevenbleifer@Stevens-MacBook-Pro.local:Library/Application\ Support/iTunesRemote/daemon/"

**The backslash before the space is not optional:** the remote shell splits
the path at the space and rsync quietly creates `~/Library/Application` and
puts the daemon there, while the real one keeps running old code. Done
that once (2026-09-04); the stray folder was removed. macOS's rsync has no
`-s`/`--protect-args`, so escaping is the only way.
    ssh -i ~/.ssh/id_ed25519_mbp2012 stevenbleifer@Stevens-MacBook-Pro.local \
        'launchctl kickstart -k gui/$(id -u)/local.itunesremote.daemon'

(`~/iTunesRemote/daemon` on the Pro is now just a staging copy; the installer
is `daemon/Install iTunes Remote Daemon.command`, double-clickable, rerunnable,
prints the pairing code. `setup.sh` is the old dev installer and is superseded.)

**Pairing.** `config.json` gained `pairing_code` (six digits, made on first
load of an old config). `GET /api/hello` (no token) says app/name/host/port/
iTunes version; `POST /api/pair {"code"}` returns the token plus the Mac's
name and its Tailscale MagicDNS name (found via `~/tailscale/tailscale`,
`/usr/local/bin/tailscale` or the Tailscale.app CLI, with the community
socket path tried too). Wrong codes cost a second; five lock pairing for ten
minutes. `python3 -m itunes_remote --pairing-code` prints the code.

**Bonjour.** The daemon registers `_itunesremote._tcp` through
`/usr/bin/dns-sd -R` as a child process (`advertise()` in `__main__.py`).
`dns-sd -B _itunesremote._tcp` from the Air sees it on both bridge0 and Wi-Fi.

**Client.** `SetupAssistant.swift` (find → pair → away → curator → done),
`DaemonBrowser.swift` (NWBrowser, then hello over the address it resolved).
First run with no token opens it; File ▸ Set Up iTunes Remote… reruns it.
ATS exception is now `ts.net` with subdomains, so any tailnet works. The
status bar has a badge (`AquaConnectionBadge`): Home · Thunderbolt / Wi-Fi /
Ethernet (the interface the probe's own request left on, from URLSession
metrics + getifaddrs) or Away via Tailscale; and "Library as of <time>".

**Dev flags:** `--setup-demo CODE` walks the assistant against the real
daemon, printing `step <name> window <N>` so `scratchpad/demo.sh` can
screencapture each page. Trap found: an NSTextField sends its action on end
editing by default, so hiding the code field advanced the assistant a page;
`sendsActionOnEndEditing = false`.

**Packaging.** `client/package.sh` → `client/build/dist/iTunes Remote <v>.dmg`
with the app, the `Daemon/` folder (installer inside) and a Read Me.
`ITR_SIGN_IDENTITY` on build.sh/package.sh signs with the hardened runtime;
`ITR_NOTARY_PROFILE` notarizes and staples. Steven has a Developer ID; he
declined a keychain check, so ask him for the identity string and the
notarytool profile name rather than looking.

**Hardening (2026-09-04):** token compare is `hmac.compare_digest` and a bad
or missing token costs 0.5 s; request bodies over 4 MB are refused (413);
no Python banner in the Server header; the pairing code rotates after every
successful pairing (rerun the installer or `--pairing-code` to read the new
one); five wrong codes lock pairing for ten minutes. Still plain HTTP: on
the LAN the token rides inside WPA, over Tailscale inside WireGuard. The
token on the Air lives in UserDefaults (a 0600 plist), not the Keychain —
an ad-hoc-signed app has no stable identity for a Keychain item, so it would
prompt on every rebuild; revisit once the Developer ID signature is in use.

## Embedded Ollama (2026-09-04, late afternoon)

The app carries Ollama 0.33.2 for Apple Silicon in
`Contents/Helpers/ollama/` — just `ollama` and `llama-server`, arm64 slices,
45 MB. The tarball's dylibs are x86-only and its `mlx_metal_*` folders
(180 MB each) are for MLX models; the GGUF models the curator uses run on
the Metal backend built into the binary. Verified: Metal on the M5,
embeddings and chat with the real models. `client/fetch-ollama.sh` fetches
the pinned release (sha256 checked) into `client/Vendor/ollama/`, which is
gitignored; build.sh copies it in when present and signs the two binaries
before the app.

`OllamaRuntime.swift`: if an Ollama app answers on 11434 it is used as is
(so Steven's own install and models keep working); otherwise the bundled
copy is started on **127.0.0.1:11435** with `OLLAMA_MODELS` at
`~/Library/Application Support/iTunes Remote/ollama/models`, logging to
`~/Library/Logs/iTunesRemote/ollama.log`. It runs under a `/bin/sh`
watchdog that kills the server when the app's pid vanishes, because
`exit(0)` in the snapshot paths skipped `applicationWillTerminate` and left
a server listening once. `--embedded-ollama` forces the bundled copy for
testing. To test without a 4 GB download, `scratchpad/seed-models.sh
<dir> qwen3.5:4b embeddinggemma:300m` hard-links the blobs from
`~/.ollama/models` (done for the app's embedded dir on the Air).

**Signing:** identity `Developer ID Application: <your name>
(<team-id>)`, notarytool profile `itunes-remote`. See memory
`apple-developer-signing`.

**Refresh button (status bar, left of the library stamp):** `POST
/api/library/refresh` makes the daemon stat the XML this instant and
reparse if it differs from what it read, skipping the watcher's
sit-still wait (`LibraryStore.check_now()`, guarded by `_reload_lock` so it
never races the watcher). Blocks for the parse (~25 s on the Pro). The
client then runs its normal version check. It cannot make iTunes *write*
the XML — nothing can — so "Nothing new" means iTunes has not saved yet.

## The curator learns (2026-09-04, evening)

Steven asked whether the model could be trained to do better. Three
layers, cheapest first, all built; the third has a pipeline but no data
yet.

**1. Lessons from edits — `client/Sources/App/CuratorMemory.swift`.** One
`Lesson` per request: the request, its embedding (256-d, from the same
query embedding as search), what the listener said (`feedback`), songs
that went out (`removed`: by feedback edit or by hand delete —
`setCurrent` diffs the list), songs that came in (`added`), and the list
as saved (`kept`, `saved`). Persisted to `curator/memory.json`, capped at
500, empty lessons dropped on `close()`. On a fresh request `recall()`
embeds the text, takes lessons with the same folded words or cosine ≥
0.62 (`similar(to:request:)`), and opens a new lesson. Uses: (a)
`gather` skips `memory.unwanted(near:)` — songs removed under a similar
lesson, or removed under any two lessons — plus one-star songs, unless
they are on the current list; (b) the choose prompt gets "What this
listener did with playlists like this before" (`summary(of:)`, up to
three lessons); (c) the plan prompt gets the listener's past remarks on
similar requests so the plan can avoid them. Verified: after a session
that took out two songs, "songs from the nineties" recalled the lesson
and neither song was among the candidates (see `curator.log`
"recalled N lesson(s)").

**2. Taste from plays — in `CuratorEngine`.** `buildTaste()` sums
playCount + 3×stars (three stars and up) per folded artist and per genre,
squashed `log1p(x)/log1p(max)` to 0…1. `searchTracks` fetches 2k by
meaning and re-sorts by `score + 0.06·artist + 0.03·genre`, so plays
break ties but never change the subject (embedding scores sit around
0.5–0.8). Candidate lines carry ♥ for artists at ≥ 0.6, with a prompt
rule to prefer them between equal fits.

**3. Fine-tune — `client/finetune/finetune.sh`.** Data: `approve(_:name:)`
runs when a list is saved (both the Save button and `--curate-save`; the
test flag `--curate-approve NAME` approves without making a playlist).
It writes the first turn's prompt with the *final* list as the answer
(only if ≥ 60 % of the final list was on that turn's table) and every
feedback turn's prompt with the edit *as applied* (remove/add/order after
the code rules), to `curator/training.jsonl` as
`{"messages":[system,user,assistant]}`. The script: private venv with
mlx-lm 0.31 on Python 3.12 (macOS's 3.9 only gets mlx-lm 0.29, which
lacks the newer models; the script finds a 3.10+ Python, or has `uv`
fetch a standalone 3.12 into `~/.local` — done on the Air, no admin
password); 90/10 split; `mlx_lm lora` on
**`mlx-community/Qwen2.5-7B-Instruct-4bit`** with `--mask-prompt` (the
prompt is a long candidate list, only the answer is learned), 8 layers,
lr 1e-5, seq 12288, grad checkpointing, iters = 6×examples clamped
100–800 (~25 s a step at 4.5k tokens);
`mlx_lm fuse --dequantize`; `ollama create itunes-curator --quantize
q4_K_M` from the fused safetensors with only `num_ctx` set (the chat
template comes from the tokenizer files; do NOT copy the stock model's
`TEMPLATE {{ .Prompt }}`, which is a built-in-renderer marker); then
`defaults write … curatorModel itunes-curator`. `ITR_NO_SWITCH=1` builds
without switching the app; `ITR_TUNED_NAME` names the model.

**Why Qwen 2.5 7B, not Qwen 3.5 (measured, 2026-09-04):** two
constraints. (1) *Trains in 24 GB:* `mlx-community/Qwen3.5-4B-MLX-4bit`
died with Metal "Insufficient Memory" at the first training step even
with examples cut to 2048 tokens — mlx-lm's `qwen3_5.py` passes
`use_kernel=not self.training` to `gated_delta_update`, so in training
the linear-attention layers (three of every four) use the plain-ops scan
that keeps every step's state for the backward pass. Gemma 4 E4B
(`gemma-4-E4B-it-qat-4bit`) also OOMs. Plain-attention models are fine:
Qwen 3 4B peaked at 10.3 GB, Qwen 2.5 7B Instruct at 12.7 GB, both at
the full 4.5k length, against an 18 GB GPU working set. (2) *Imports into
Ollama:* `ollama create` from safetensors (Ollama 0.33.2) refused Qwen 3
with `unsupported architecture "Qwen3ForCausalLM"` — `convert/convert.go`
takes `Qwen2ForCausalLM` and `Qwen3_5ForConditionalGeneration` but not
plain Qwen 3. Qwen 2.5 7B satisfies both. Two other snags fixed on the
way: `mlx_lm fuse` opens the base offline and the hub library rejects a
snapshot missing README/.gitattributes, so the script completes the
snapshot first; and mlx-lm needs Python 3.10+. The examples' prompts are
~4.4k tokens each (two on file after the test session). The setup
assistant's model popup lists a non-tier model as "Trained on your
edits". It refuses under 40 examples without `--force`. Runs on the
embedded Ollama too (`OLLAMA_HOST=127.0.0.1:11435`, `OLLAMA_MODELS` under
Application Support) when the Ollama app is not running.

**Bug found by the test:** an edit's top-up (`fill`) refilled from the
candidates, whose head is the current list, so the songs the edit had
just removed came straight back at the end with blank reasons. `fill`
now takes `exclude:` and `applyEdit` passes the removed ids.

**Layout:** the curator split's autosaved frames from the Studio Display
kept their 1279-pt total on the 1470-pt built-in screen, so the right
pane ran past the window edge; `layout()` now calls `adjustSubviews()`
whenever the panes do not span the split.

**In-app training (2026-09-04, late).** `Controls ▸ Train Curator on My
Edits…` opens `TrainingWindow.swift` (a ChromeView window like the setup
assistant, 560×430). `CuratorTrainer.swift` (singleton, outlives the
window) runs `Contents/Resources/finetune.sh` — build.sh copies it from
`client/finetune/` — under `/bin/bash` with `ITR_PROGRESS=1`,
`ITR_NO_SWITCH=1` (the app writes `curatorModel` itself on exit 0), a PATH
that reaches `~/.local/bin`, `/usr/local/bin` and Homebrew, and, when the
embedded Ollama is the one in use, `ITR_OLLAMA` + `OLLAMA_HOST` +
`OLLAMA_MODELS` so the import lands in the app's own store. The script
gained `--check` (examples, minimum, python, tuned, stock — what the
window shows), `--fetch-python` (uv from astral.sh into `~/.local/bin`,
then `uv python install 3.12`; ~100 MB, no admin), `@@stage …` /
`@@iters N` progress lines, and a TERM trap: every long step runs via
`step` (child + wait) so Stop, or the app quitting
(`applicationWillTerminate` → `cancel()`), reaches mlx-lm rather than
leaving it on the GPU. The window parses mlx-lm's `Iter N:` lines for the
bar. Flow: Train → under the minimum, "Train Anyway"/Cancel → one consent
alert naming what is fetched (Python + library if missing, base model
first time) → `ensureRunning()` for Ollama → `--fetch-python` first if
needed, then the training run. Exit 0 sets `curatorModel` (to
`ITR_TUNED_NAME` if that is in the app's environment, for tests) and
plays Glass; 130/143 is "Stopped". "Use Stock Picker" and "Delete
Training Data" (removes training.jsonl only) sit on the left.

Testing it: launch the built app with `ITR_ITERS=10 ITR_MIN_EXAMPLES=1
ITR_TUNED_NAME=itunes-curator-smoke` in the environment (the child
inherits it), open the window from the menu, press Train. With two
instances running, target System Events by pid (`first process whose
unix id is N`) — the installed app has the same name. `build/windowid`
does not find this window; capture the screen with `screencapture -x -m`
instead. Verified 2026-09-04: the run streamed into the window, imported
`itunes-curator-smoke`, and the app switched to it; then reverted and the
smoke model removed.

## Audit pass (2026-09-04, evening)

Steven asked for a sweep of the whole app for bugs and inefficiencies.
Every file in `client/Sources` and `daemon/itunes_remote` was read, plus
the hot-path AppleScripts. Fixed in this pass:

- **Next track swallowed after a resume** (`PlayerController`):
  `suppressFinish` was set on every play/pause, including a resume, and
  only cleared by a later stop; the next natural end of a track was then
  taken as a deliberate stop and nothing followed. Now set only when
  pausing from playing, and cleared by any poll that shows playing.
- **Sync/Eject buttons acted on the wrong device** (`MainWindowController`):
  `devices.first` could be an iPhone on the USB bus rather than the iPod;
  now the first iPod. Eject drops only that device from the list.
- **Local playback KVO crash risk** (`LocalPlayer`): the status observer
  was removed only when the first status change arrived; two quick track
  changes could deallocate an observed item. The observer now follows one
  `observedItem` and comes off before the item is replaced.
- **Album dot on the iPod's Music pane never showed** (`DevicePageView`):
  the device lists albums as "Artist - Album" and the match used the bare
  title.
- **Double-click on a playlist played the previous list's first song**:
  the click's reload had not finished; now `playFirstWhenLoaded` waits
  for the rows.
- **Media keys**: Play and Pause both toggled; Control Centre's Play on a
  playing app paused it.
- **Grid memory**: every cover ever scrolled past stayed decoded (9,135 ×
  ~90 KB); covers far from the visible rows are let go past 600.
- **Column sorts on the full library** (`LibraryController.applySort`):
  the six-field artist key was built inside the comparator, a few million
  times per sort; keys are computed once per track and indices sorted.
- **Cover Flow scrub** filtered 93k tracks on every mouse move
  (`coverSelectionChanged`); coalesced to one refresh per run-loop turn.
- **Music pane ticks** rebuilt all four lists (9k album rows) per tick;
  only the touched list now.
- **Daemon**: `_reconcile_artwork_flags` stat-ed the disk cache for every
  no-art album on every `/api/albumlist` (thousands of stats per browser
  click on the Pro) — settled answers are remembered per Library object;
  `itunes_running()` spawned `pgrep` before every script (twice a second
  with the player poll) — cached 2 s; the warmer's `queue.pop(0)` is a
  deque; duplicate `server_version`; misplaced docstring in
  `_connected_pod`; a non-numeric Content-Length was a 500, now a 400;
  `sync_rebuild.applescript` treated an album selection with no artist
  as "artist is empty" where the daemon's count treats it as any artist.

Noted, not changed (Steven's call or bigger jobs):

- **Reconnect button** (rightmost in the bottom-left row, `reconnectButton`):
  largely redundant now. Reconnection to a restarted daemon is automatic
  (`LibraryController` retries, `ConnectionMonitor` switches hosts), and
  the Refresh button re-reads the library. What it still uniquely does is
  clear the artwork cache. Recommendation: remove it, or fold "clear the
  art cache" into Refresh.
- The daemon token lives in UserDefaults in plain text; the Keychain
  would be the right place. The token also rides in the audio URL's query
  string for AVFoundation, which the daemon accepts (`?token=`); the
  `AVURLAssetHTTPHeaderFieldsKey` header is set too, so the query copy may
  be droppable — untested.
- "MacBook Pro" is hard-coded in a dozen user-facing strings; for other
  people's installs the daemon's `name` should be used.
- `/api/library` is probed every 45 s by the connection monitor even at
  home; harmless but could back off.
- `library.albums()` regroups 93k tracks on every album list; a per-Library
  cache of the unfiltered result would make browser clicks on the Pro
  faster still.
- `AlbumGridView` decodes images on the main thread on first draw.

## Artwork editing, and the Reconnect button gone (2026-09-04, night)

**Artwork.** Daemon: `PUT /api/tracks/artwork` with `{ids, image}` (base64
JPEG or PNG, sniffed, ≤ 3 MB, `MAX_BODY` raised to 6 MB for the base64)
and `DELETE /api/tracks/artwork` with `{ids}`. Both run
`artwork_set.applescript` (reads the picture outside the iTunes tell
block as «class JPEG»/«class PNGf», deletes existing artworks, then
`set data of artwork 1 of t`, which makes the artwork when there is none)
or `artwork_clear.applescript`, 25 tracks a run, and then settle every
cache the answer lives in: the memory LRU, the disk cache (`put`), the
in-memory track's `artwork_count`, and the per-library `_art_flags`. So
the new cover shows at once; when the XML catches up the cache's
date-modified check re-exports from iTunes anyway. Verified end to end
against iTunes on the Pro: set → `count of artworks` 1 → clear → 0, on a
track that had none (left as it was).

Client: `APIClient.setArtwork(ids:image:)` / `clearArtwork(ids:)`
(`PatchResult` now decodes either `updated` or `changed`);
`ArtworkCache.forget(_:)`; the Get Info sheet (`InfoPanel`, now 640 wide)
has an `ArtworkWell` (drop target for image files or images, click →
`NSOpenPanel`) with Choose… and Remove stacked under it; the change
travels in the apply payload as `artwork` (JPEG Data from
`InfoPanel.coverData`, ≤ 1400 px, quality 0.9) or `clearArtwork`, and
`showGetInfo`'s apply splits it into its own call, then
`artworkChanged(ids)` forgets the cache, reloads the album views and the
side panel. `--get-info` opens the sheet on the first row at launch and
prints the sheet's window number, since `windowid` does not list windows
on a second display — `screencapture -l <that number>` gets the sheet.

**Reconnect button removed** (`reconnectButton`, `reconnect(_:)`): its
one remaining job, clearing the artwork cache, moved into the Refresh
button. Reconnection and home/away switching were already automatic.

## Seven features in one pass (2026-09-04, late night)

Steven asked "are there any other features you think should be added?",
I listed seven, and he said "all of them" — with the note that More Like
This had to be an *addition* to the curator, keeping the page and the
conversation exactly as they were. All seven are in; here is where each
lives and what to know.

**Daemon.** `Track` gained `play_date` (XML "Play Date UTC") → `lastPlayed`,
and the compact rows now carry `lastPlayed` and `bitRate`. Lyrics are not in
the XML at all, so there is `GET /api/tracks/<pid>/lyrics` running
`lyrics_get.applescript` (mind: `words` is a reserved word in AppleScript;
the first draft used it as a variable and failed with "Can't make every
word into type Unicode text"). `PATCH /api/tracks` accepts `lyrics`; it is
in `Api.EXTERNAL_FIELDS`, written to iTunes but never into the in-memory
library, and `head.append(Track.EDITABLE.get(internal, internal))` is
what lets a field that `Track` does not carry reach the script. iTunes
hands lyrics back with `\r`; the client normalises to `\n`. Verified round
trip on 91A140968E8BD5E9 (set, read, cleared).

**Deploy trap, again.** rsync to the Pro must escape the space:
`"…:Library/Application\ Support/iTunesRemote/daemon/"`. The Pro's rsync
is 2.6.9 and splits an unescaped remote path at the space, so a deploy
with `"Library/Application Support/…"` silently lands in
`~/Library/Application/` on the Pro and the daemon keeps running old
code. I did exactly that once tonight, found the stray copy, removed it,
and redeployed. The recipe in the memory file has the backslash; keep it.

**Client.**
- `Duplicates.swift`: same folded title + artist, clustered by length
  within 2 s, keeper first (`keepFirst`: bit rate, rating, plays, date
  added). `Source.duplicates` in `LibraryController` fetches like the
  library (so the browser panes still narrow it) and replaces the page
  with the groups; `duplicateExtras` greys the extras in the table cell.
  Sidebar row under LIBRARY, `duplicatesShown` (default on), View ▸ Show
  Duplicates. On this library: 6,448 songs with copies, 8,297 extras,
  76.91 GB. `--source duplicates` for screenshots.
- `InfoPanel`: single-song sheets get an `InfoTabStrip` (Info | Lyrics);
  `infoViews` hide when Lyrics is up; `loadLyrics` fetches on present,
  `initialLyrics` nil means "could not read" and the view stays
  read-only. `--get-info --info-lyrics` opens the sheet on the tab.
- `lastPlayed` column, sort case, optional-columns list.
- `MissingArtworkWindow.swift`: albums with `hasArtwork == false` from the
  album list (a settled miss in the daemon's caches, not a "maybe"),
  iTunes Search (`itunes.apple.com/search?media=music&entity=album`),
  600×600 art by rewriting `100x100bb`, `agrees()` requires the
  simplified album names to be equal (a prefix rule matched "Cassadaga: A
  Companion" for "Cassadaga", so it went) and the artist to agree or
  contain; Find All sleeps 2.5 s between lookups because the service
  throttles. Writes go through `api.setArtwork` on the album's track ids
  (fetched by album, filtered by display artist) and `api.dropCache()`
  after. 858 albums qualified here. `--missing-art`, and `--find-art
  "Artist|Album"` (+ `--find-art-apply`) script one lookup. I stopped short
  of an end-to-end write test: Steven declined the bulk store scan I was
  running to find an exact match, so the write path is verified only as
  the same `setArtwork` call the Info sheet uses.
- More Like This: `CuratorEngine.ask(_:seeds:)`; a seeded ask resets and
  keeps `seeds`; `gather` inserts the centroid's 40+ nearest and each
  seed's 8 nearest ahead of the phrase lists (`CuratorIndex.vector(of:)`,
  `centroid`, `searchVector`); the plan prompt lists up to twelve seed
  songs and the seed's artists join `plan.artists`; seed ids and
  title|artist keys are refused by `take`. Text lessons are not recalled
  for a seeded request (the small embedding model scored "More songs like
  the album Abbey Road" against "90s road trip" above 0.62). Entry points:
  track menu "More Like This", sidebar "Make a Playlist Like This…" (up to
  400 songs of the playlist). `--like "Artist|Album"` for testing; the
  Abbey Road run produced a sensible 20 in 42 s.
- Up Next: `upNext.didSet` writes `upNextQueue` (array of
  `Track.defaultsDict`), `restoreUpNext()` in `firstLoadDone`.
  `Track(defaults:)` lives in an extension so the memberwise init survives.
- `SongNotifier.swift` (UserNotifications): one identifier so banners
  replace each other, cover as a 256 px JPEG attachment from the artwork
  cache, permission asked on the first post. Fired from `updatePlayerUI`
  when the song id changes and the window is out of sight. Not exercised
  live — the permission dialog would have popped on Steven's screen.
- `TokenStore` (Security): generic password, service
  `local.stevenbleifer.itunesremote`. Enabled only when the running app
  has a Team ID (`SecCodeCopySigningInformation`), and never with
  `--token`. `ServerSettings.load` migrates a UserDefaults token into the
  keychain and removes it from defaults only after the write succeeded;
  `save` falls back to defaults if the keychain refuses.
- `ServerSettings.name` (defaults `serverName`, set from the hello at
  pairing, default "MacBook Pro"); every "MacBook Pro" string in the
  client and the daemon's two user-facing ones now use the paired Mac's
  name.
- App icon replaced with the iTunes 10 icon Steven supplied
  (`~/Downloads/itunesicon512.png` → `Resources/AppIcon.iconset` via sips
  → `AppIcon.icns`).

**Screenshot tooling correction.** `build/windowid` takes the *owner
name*, which for the bundled app is "iTunes Remote" (with the space), and
prints every on-screen window of that process with its title; grep the
title you want. It cannot see sheets; `--get-info` prints the sheet's
window number for `screencapture -l`.

## Find iPod (2026-09-04, later)

"Sometimes when I plug the iPod in it still doesn't mount — a button that
searches for it and mounts it?" There is now `POST /api/devices/find`
(`post_devices_find`): clears the USB cache, reads `system_profiler`, reads
iTunes' sources, and answers `state` = `open` | `absent` | `wedged` with a
sentence. With `{"restart": true}` the wedged case quits and relaunches
iTunes (same steps as `post_itunes_restart`) and polls the sources every
5 s for 75 s. Client: `api.findIPod(restart:)`, `MainWindowController.
findIPod` (Controls ▸ Find iPod…, `--find-ipod` prints the state), the
sheet `offerITunesRestart`, and a Find iPod button on the device page in
Sync's place when `unavailableReason` is set.

What I learned testing it, with the iPod actually wedged at the time
(plugged 21:11, serial 000A270013356E00): the iTunes restart did **not**
clear it this time, unlike 2026-09-03. The ioreg tree was complete down to
`IOBlockStorageDriver` with **no IOMedia child**; `Bus Power Available` was
normal; the kernel log had only the USBMSC enumeration line. I tried
`IOServiceRequestProbe` (a ctypes script, no root) on the iPodSBC nub, the
SCSI logical unit and the block storage driver: every call returned
0xe00002c7, kIOReturnUnsupported. So when the iPod does not offer its
medium there is nothing user-space on the Pro can do; the message says to
replug or reset the iPod (Menu + centre until the Apple logo) and to let
it charge if the battery is low. Nothing in the app can mount what the
device is not presenting, and the feature is honest about that.

**The real cause, found an hour later.** Steven reported the iPod's screen
said "Connected", then "Ejecting", then "OK to disconnect". The unified log
for 21:11:56, nine seconds after the USBMSC enumeration:
`loginwindow: CopySLMountApprovalCallback | DiskArb - wholeDisk != nil,
calling DADiskEject`, and `ioreg -n Root -d1 -a` showed
`CGSSessionScreenIsLocked = 1`. **macOS will not mount a removable disk
plugged in while the screen is locked; loginwindow ejects it.** That is
the whole "wedge": the Pro's screen was locked. The iTunes-restart story
from 2026-09-03 was a coincidence (the screen must have been unlocked in
between), and the "lock/unlock made no difference" note was wrong too.
`post_devices_find` now checks the lock first (`_screen_locked`) and
answers `state: "locked"` with the fix in words; the client shows it as a
plain alert with no restart offer. The memory file `itunes-device-wedge`
is corrected.
