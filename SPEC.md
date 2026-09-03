# iTunes Remote Control: Build Specification

*Revised 2026-09-02 against the actual MacBook Pro: iTunes version, library size, Python support, and several deployment details were corrected after measuring them on the machine.*

## 1. The problem

I have a single canonical iTunes library that lives on a 2012 MacBook Pro running macOS Mojave (10.14). That machine runs headless. It holds several hundred GB of music: CD rips inherited from a family library, vinyl recordings I make myself, and iTunes Store purchases. It is also the machine my iPod plugs into for syncing.

Today the only way to touch that library is to Screen Share into the Mojave machine from my MacBook Air. It is slow, laggy over Wi-Fi, and painful for anything involving repetitive clicking like fixing genre tags across a lot of tracks.

I want an app that runs on my MacBook Air (M5, macOS current) and controls iTunes on the MacBook Pro over the local network. The Air is the interface. The MacBook Pro does the actual work.

## 2. Scope

### In scope

- Browse and search the entire library
- Edit track metadata, with genre as the primary case, including bulk edits across many selected tracks
- Create and edit playlists
- Control playback on the MacBook Pro (play, pause, next, previous, select track, volume)
- Choose the AirPlay output on the MacBook Pro: Computer, HomePods, Apple TV, or any combination iTunes allows (added 2026-09-02)
- Show album artwork for the playing track and the selected track, read-only (added 2026-09-02)
- Trigger an iPod sync, conditional on a capability probe described in section 7

### Explicitly out of scope

- Do not clone the iTunes interface. Build only the screens needed for the functions above.
- No audio streaming to the MacBook Air. Playback happens on the MacBook Pro, which is wired into a receiver. This app is a remote control, and audio never crosses the network.
- No album art editing: no adding, replacing, or removing artwork. Showing it is in scope.
- No smart playlist rule editing, no store integration, no Apple Music.
- No write path to the library files on disk. Every mutation goes through iTunes itself.
- No iPad client. The client is AppKit only (section 4.2), and AppKit does not run on iPadOS. If an iPad front end is ever wanted it is a separate project against the same HTTP API.

## 3. Hardware and environment

**Server side (the MacBook Pro):**
- 2012 15" MacBook Pro, non-Retina unibody, 16GB RAM, 2TB SSD
- macOS Mojave 10.14.6, iTunes 12.9.5 (the last iTunes for Mojave)
- Runs headless, on Wi-Fi, on a UniFi network
- Library lives on the internal SSD
- No `python3` installed today. Only the system `/usr/bin/python` 2.7 and `perl` exist.

**The library, measured 2026-09-02:**
- 95,688 file tracks and 75 user playlists reported by iTunes
- 102,354 entries in the XML, because it also carries cloud-only movies and TV episodes, voice memos, and other non-music items
- `iTunes Music Library.xml` is 163 MB; `iTunes Library.itl` is 59 MB
- 467 pre-existing duplicate entries point at files that are also referenced by another entry. The browser will show both. Editing one leaves the other stale until iTunes re-reads the tag. This is a known wart, not a bug in the app.

**Client side (the MacBook Air):**
- MacBook Air M5, 24GB RAM, current macOS (26.x)

## 4. Architecture

Two pieces.

### 4.1 Daemon on the MacBook Pro

A small HTTP server on the LAN. It is the only thing that touches iTunes.

**Language and dependencies:** Python 3.13 from python.org, not Homebrew, because Homebrew no longer supports Mojave. Pin 3.13 specifically: its installer is listed "for macOS 10.13 and later", while the 3.14 installer requires macOS 10.15. 3.13 receives security fixes into 2029. Installing it is a real setup step, since the machine has no `python3` at all today. Use the standard library only. No pip packages. `http.server` for the server, `plistlib` for the library file, `subprocess` for AppleScript. Zero dependencies means nothing breaks when some wheel drops support for an eight-year-old OS.

**Reads come from the library XML file.** The file at `~/Music/iTunes/iTunes Music Library.xml` is an XML plist and `plistlib.load()` parses it directly. Load it once at startup into memory and hold it there.

Measured numbers, so nobody has to guess: parsing the real 163 MB XML with `plistlib` on the M5 Air takes 5.1 seconds and leaves the process at about 526 MB resident. Expect roughly 20 to 30 seconds on the 2012 i7. A substring scan across every track takes about 25 ms, so the sub-second search target is easy once the data is in memory.

Filter at load time. Serve only entries whose `Track Type` is `File` and whose `Kind` is audio. The cloud-only movies, TV episodes, and other non-music entries account for the gap between 102,354 XML entries and 95,688 file tracks.

This is the single most important design decision in the project. Do not query iTunes over AppleScript to enumerate the library. On a library this size that takes minutes and the app will feel broken. AppleScript is for writes and playback only.

**Writes go through AppleScript**, executed via `osascript`.

**Cache invalidation:** watch the XML file's modification time and reload when it changes. iTunes rewrites that file lazily and slowly on a large library, so do not wait for it after a user edit. When the app successfully writes a genre change, patch the in-memory record immediately so the UI reflects it right away.

Reload in a background thread and swap the parsed dictionary in atomically under a lock. A reload takes tens of seconds on this machine, and a reload on the request thread would freeze every read for that long. If the parse fails, assume iTunes was mid-write, keep the old data, and retry after a short delay.

**Concurrency:** `http.server.HTTPServer` is single threaded. Use `ThreadingHTTPServer` so reads keep flowing while a bulk write runs. Serialize every `osascript` invocation behind a single lock so iTunes never receives concurrent Apple Events. A 300 track edit that blocked every read until it finished would produce exactly the frozen feeling this design is trying to avoid.

### 4.2 Client UI

A native macOS application, written in Swift using AppKit. Not SwiftUI, and not a web view.

The reason is section 5A. This app has to be styled like iTunes 10 (section 5A), which means nearly every control is custom drawn. SwiftUI fights you on custom drawing and gives you modern system controls you then have to hide. AppKit is built around `NSView` subclasses that draw themselves, which is exactly the job.

AppKit also solves the list problem for free. `NSTableView` is view based and recycles rows, so it handles a library of roughly 100,000 tracks without any virtualization work on my part. This is a genuine advantage over the web approach I originally proposed.

**Build target:** the client runs on my M5 MacBook Air on current macOS. The Mojave and standard-library-only constraints in this document apply to the daemon only. The client can use anything modern.

The layout should follow the classic iTunes three pane arrangement: source list on the left, browser panes for genre and artist and album across the top, track table filling the rest, transport controls and status display in the toolbar.

## 5A. Visual design: iTunes 10

This is a requirement, not a nice to have. The app should look like iTunes 10 on Snow Leopard or Lion, 2010 to 2011. (Revised 2026-09-02: the original target was the brushed-metal iTunes 6/7 look; that was dropped after seeing it.)

**Target look:**

- A unified light gray toolbar, a flat vertical gradient with a one pixel darker line under it. No brushed metal anywhere. No window title; the toolbar carries the display instead.
- Round silver transport buttons at the left: previous, a larger play/pause, next. Light-to-dark gray gradient, thin dark border, dark gray glyphs, a soft shadow beneath.
- A small horizontal volume slider beside them with speaker glyphs at each end, gray groove, round silver knob.
- The recessed display in the middle of the toolbar: pale gray, rounded corners, inset shadow along the top, dark gray Lucida Grande text showing track, artist, album, and a scrubber.
- The capsule search field at the right.
- A blue-gray source list on the left with uppercase bold gray section headers (LIBRARY, PLAYLISTS) that have a faint white emboss, and a blue gradient selection with white text.
- Column browser panes (Genres, Artists, Albums) across the top of the track area, white with gray gradient headers.
- The track table with alternating white and very pale blue rows, gray gradient column headers with a sort triangle, hairline column dividers, blue gradient selection with white text when focused and gray when not.
- A light gray status bar along the bottom with the "N songs, X days, Y GB" summary centered.

**Everything must be drawn in code.** Do not extract artwork from old macOS system files, old iTunes application bundles, or screenshot archives. That is Apple's copyrighted artwork and I am not shipping it. Recreate the look with Core Graphics: gradients, inner and outer shadows, stroke highlights along the top edge of controls. If a raster asset is genuinely unavoidable, draw an original one.

The one sanctioned exception (added 2026-09-02): Apple's system symbols obtained through the `NSImage(systemSymbolName:)` API. Those are provided for apps to use, are rendered by the system at run time, and nothing is copied into the bundle. The AirPlay button uses the `airplayvideo` symbol this way after two hand-drawn attempts looked wrong.

**Font:** Lucida Grande. It still ships with macOS (confirmed present as `LucidaGrande.ttc` on macOS 26.6.2) and is the single biggest contributor to the period-correct feel. Do not use San Francisco anywhere.

**Controls to build as custom `NSView` subclasses:**

- Round silver transport buttons for previous, play or pause, next
- The horizontal volume slider with the round knob and speaker glyphs
- The display panel, recessed with an inset shadow, showing track title, artist, album, and a scrubber
- Push buttons for dialogs, in the Snow Leopard style: a blue default button with a soft gloss, white otherwise (the milestone 2 gel button, toned down)
- Table header cells with the gradient and the sort triangle
- Source list section headers with the embossed uppercase text
- Scroll bars in the Snow Leopard style, and the capsule search field, in the polish milestone

**Table styling:** alternating white and very pale blue rows. Selected rows use the gradient blue highlight with white text. Column dividers are hairlines.

**Getting this wrong in the obvious way:** flat colors and hard edges will read as a modern app wearing a costume. The look came from subtle gradients, one pixel highlight and shadow lines, and a light source that is always top center. Build the chrome and get my sign off before polishing the rest.

**Dark mode:** ignore it entirely. Lock the app to a light appearance. iTunes 10 had no dark variant and faking one will look wrong.

## 5. Track identity

The XML gives each track two identifiers:

- **Persistent ID**, a hex string that is stable across library rebuilds
- **Track ID**, an integer that iTunes uses internally

Use Persistent ID as the application's primary key. It is what goes in URLs and in the UI's selection state.

For AppleScript lookups, use Track ID, because `track id N of library playlist 1` resolves fast, while a `whose persistent ID is "..."` clause scans the whole library and is slow.

Because Track ID is not guaranteed stable, every write must verify. Fetch the track by Track ID, read back its persistent ID, and confirm it matches the one the client asked for. If it does not match, fall back to the slow `whose` lookup and update the cached Track ID. If that also fails, return an error rather than writing to the wrong track. Silently tagging the wrong song is the worst possible failure mode here.

**Measured 2026-09-02, and this changes the plan above.** The XML `Track ID` is the AppleScript `database ID`, and it is *not* the AppleScript `id`: for one Radiohead track the XML said 72685 and `id` was 260077, so `track id 72685 of library playlist 1` fails with -1728. Meanwhile the "slow" lookups are not slow on this library: `first track of library playlist 1 whose persistent ID is "..."` and `whose database ID is N` each take about 0.2 s net of process spawn, and about 75 ms per lookup when batched inside one script (30 lookups in 2.4 s). So the daemon looks tracks up by **persistent ID directly** and never touches Track ID for AppleScript. The verification step above is kept as a read-back assertion, which is now trivially cheap. A 300-track bulk edit is expected to take roughly 20 to 25 seconds inside one script; milestone 6 should try `whose persistent ID is in {...}` to see whether iTunes does that in one pass.

**Verify which AppleScript property the XML Track ID matches (original note, superseded by the paragraph above).** The XML's `Track ID` corresponds to the AppleScript `database ID` property. The form `track id N` resolves the separate `id` property. In the library playlist the two are usually equal, but that is an assumption to test in milestone 5 with a handful of tracks, not something to build on blind. If they differ, look up by `database ID` and fall back to persistent ID as above.

## 6. AppleScript execution rules

**Never build AppleScript by string concatenation with user data.** Write each script as a `.applescript` file with an `on run argv` handler and pass values as arguments:

```
osascript /path/to/set_genre.applescript 12345 "Post-Punk"
```

Concatenating a track title containing a quote into a script will break it, and worse, is an injection path.

**Batch bulk edits into a single script invocation.** Setting the genre on 300 tracks must be one `osascript` call that loops inside AppleScript over a list of IDs. Do not spawn 300 subprocesses. Each launch costs meaningful time and the UI will appear frozen.

Inside that loop, iterate with `repeat with t in theList`, never `item i of theList`. Indexed access on an AppleScript list is linear per access, so the indexed form is quadratic overall. It is harmless at 300 items and pegs a core for minutes at a few thousand.

**Read old values inside the same script.** The batch script reads the current genre of each track before setting it and returns old and new pairs to the daemon. Do not take old values from the in-memory XML cache, which is minutes stale on this library.

**Every AppleScript call gets a timeout.** iTunes 12.9.5 on this hardware can stall. A hung Apple Event must not hang the HTTP server. Return a clear error to the client instead.

A timeout is not a failure. Killing `osascript` does not cancel the Apple Event already inside iTunes, and the write may still land after the daemon has returned an error. Log timed-out writes as `unknown`, not `failed`, and re-read the affected tracks before any retry so the log's old values stay honest. Treat AppleEvent error -1712, which busy iTunes throws on this machine, the same way.

**Player state polling is not free.** Each `osascript` launch costs a noticeable fraction of a second on this hardware. Poll `/api/player` about once a second, and only while the client window is frontmost.

**All writes are logged** to a rotating local file: timestamp, operation, track persistent IDs, old value, new value. When something goes wrong in a bulk edit I need to know exactly what changed.

## 7. iPod sync

The iTunes scripting dictionary has historically exposed an `update` command for iPod sources:

```applescript
tell application "iTunes" to update source "IPOD_NAME"
```

**Do not assume this works in iTunes 12.9.5.** Before building any sync feature, write a probe script and run it on the actual machine with the iPod connected. Report the result.

- If it works: expose sync in the UI. Show connected sources, let me pick one, fire the update, and report success or the AppleScript error verbatim. There is no reliable progress reporting, so show a "sync started" state rather than a fake progress bar.
- If it fails: build nothing. Leave sync out of the app entirely. Do not fall back to GUI scripting the sync button through System Events. That approach breaks on any UI change and can click the wrong thing, and I would rather screen share for that one task.

The device is a classic-style iPod with an `iPod_Control` folder, which is the kind `update` was written for, so the probe has a fair chance.

**Probe result, 2026-09-03: it works.** With the iPod classic (160 GB) connected, `update source` on iTunes 12.9.5 returned without error and iTunes began syncing. Sync is therefore built: the sidebar shows a DEVICES section with the iPod and its free space, the bottom bar gains Sync and Eject buttons, and the daemon exposes `GET /api/sources`, `POST /api/sources/{name}/sync` and `POST /api/sources/{name}/eject`. The probe is kept as `daemon/probe_ipod.sh` for re-running after an iTunes update.

**Known hazard:** an iPod left mounted in disk mode at `/Volumes/iPod` made iTunes hang at launch on every attempt, including after a reboot, until the volume was unmounted. `check.py` must report whether `/Volumes/iPod` is mounted, and the sync UI should offer to eject the iPod afterward.

## 8. HTTP API

Rough shape. Adjust as needed but keep it this simple.

```
GET  /api/library                 metadata: track count, last XML load time
GET  /api/tracks?q=&genre=&artist=&album=&offset=&limit=
GET  /api/tracks/{persistentId}
GET  /api/genres                  distinct genres with counts
GET  /api/artists
GET  /api/playlists
GET  /api/playlists/{persistentId}/tracks

PATCH /api/tracks                 bulk metadata write
      body: { ids: [...], fields: { genre: "..." } }

POST /api/playlists               create
POST /api/playlists/{id}/tracks   add tracks
DELETE /api/playlists/{id}/tracks remove tracks

GET  /api/player                  current state
POST /api/player/play             optionally with a track or playlist id
POST /api/player/pause
POST /api/player/next
POST /api/player/previous
POST /api/player/volume

GET  /api/outputs                 AirPlay devices: name, kind, selected, active, available
POST /api/outputs                 body: { names: [...] }  sets the current AirPlay devices

GET  /api/tracks/{persistentId}/artwork   image bytes, or 404
GET  /api/artwork?artist=&album=          one cover per album, for Cover Flow

GET  /api/itunes                  { running, ipodMounted }
POST /api/itunes/launch           refuses while an iPod volume is mounted
POST /api/player/position         body: { position: seconds }

GET  /api/sources                 connected devices with free space and capacity
POST /api/sources/{name}/sync     fires `update`; returns "started"; no progress is available
POST /api/sources/{name}/eject
POST /api/player/shuffle          body: { enabled: bool }
POST /api/player/repeat           body: { mode: "off"|"one"|"all" }
GET  /api/albumlist               one row per album under the current filters
```

Bind to the LAN interface. This runs on a trusted home network behind a UniFi router, so a shared token in a config file is sufficient. Do not build user accounts. Do not expose it to the internet.

## 9. Deployment on Mojave

These are the things that will actually break. Handle them explicitly and document them in a README.

1. **Automation permission.** The daemon needs TCC approval to send Apple Events to iTunes. On a headless machine the prompt is easy to miss. The approval is attributed to the responsible process, so running the daemon by hand from Terminal approves Terminal, not the LaunchAgent's Python, and the daemon will prompt again the first time launchd starts it. The setup instructions must say: connect over Screen Sharing, load the LaunchAgent with `launchctl`, approve the prompt that names Python, then verify under System Preferences, Security and Privacy, Privacy, Automation. Note that `osascript` over SSH reaches the Aqua session and works without a prompt on this machine, which is convenient for development but is not the path production takes.

2. **Apple Events require a GUI session.** The MacBook Pro must be set to log in automatically to the desktop. Install as a LaunchAgent in `~/Library/LaunchAgents`, not a LaunchDaemon. A LaunchDaemon runs pre-login and cannot talk to iTunes.

3. **The XML file must exist.** iTunes writes it only when "Share iTunes Library XML with other applications" is enabled in Preferences, Advanced. If the file is missing at startup, fail loudly with that exact instruction rather than starting up empty.

4. **iTunes must be running.** If it is not, either launch it from the daemon or return a clear error. Do not let AppleScript silently auto-launch it mid-request and time out.

5. Include a `setup.sh` that installs the LaunchAgent, and a `check.py` that verifies all of the above and prints a pass or fail line for each. It should also check that the interpreter is python.org 3.13, that iTunes is 12.9.5, and that no iPod volume is mounted.

## 10. Build order

Do not build this all at once. Each milestone should be independently working and testable.

1. **Read path.** Daemon parses the XML, serves `/api/tracks` with search and filtering. Develop against a copy of the real XML on the Air, then confirm on the MacBook Pro that startup and background reload behave at that machine's speed and that search returns in well under a second. No AppleScript yet.
2. **One control.** Build the push button as a standalone `NSView` in a throwaway test window. Nothing else. Show it to me and iterate until it looks right. (Done and signed off 2026-09-02 as a Tiger-style gel button; it gets toned down to the Snow Leopard style during polish.)
3. **UI, read only.** Native window, iTunes 10 chrome, `NSTableView` track list, search field, genre and artist browser panes. Wired to the read API. This alone already beats Screen Sharing.
4. **Playback control.** First AppleScript integration. Small surface, easy to verify, proves the Apple Events path and TCC setup work. Also the point at which the transport controls and status display get built. Includes the AirPlay output picker (iTunes 12.9.5 exposes `AirPlay device` objects and `current AirPlay devices`; verified 2026-09-02 that the machine lists eight) and artwork display: the daemon reads embedded artwork from the file named in the XML, which is a read, not a write, and falls back to the track's `artworks` over AppleScript.
5. **Single track metadata write.** Includes the persistent ID verification logic from section 5 and the write log. Start by confirming on a few tracks whether `id` and `database ID` match the XML Track ID, and record the answer in the README.
6. **Bulk genre editing.** Multi-select in the table, batched into one AppleScript call. This is the feature I want most.
7. **Playlists.** Create, add, remove.
7a. **Cover Flow** (added 2026-09-02). A view switcher in the toolbar like iTunes 10's (list, album list, grid, Cover Flow). Cover Flow is the iTunes 10 look: a black reflective stage above the track table, the selected album's cover facing forward with the neighbors angled away on both sides, mirrored reflections below, the album title and artist centered under the cover, a scrubber to flip through albums, and arrow keys to step. The daemon serves one cover per album (the first track in the album with artwork). Modern niceties that do not break the look: smooth animation at the display's refresh rate, Retina-sharp covers, trackpad swipe and pinch to flip and resize, a search that jumps the flow to the first matching album, and covers loaded lazily with a placeholder so a 9,000-album library does not stall.
8. **Remaining Aqua polish.** Scroll bars, table headers, search field, window chrome refinement.
9. **iPod sync**, only if the section 7 probe succeeded. (Probe passed and sync built 2026-09-03.)

**Status 2026-09-03:** milestones 1 through 9 are built. The remaining open items are in HANDOFF.md: running `setup.sh` for the LaunchAgent and Automation approval, the Album List and Grid views, and artwork sourcing at Cover Flow scale.

## 11. Acceptance criteria

- Searching the full library returns results in under one second
- The track list scrolls smoothly with the full library loaded
- The app is visually indistinguishable at a glance from iTunes 10 on Snow Leopard or Lion
- No Apple artwork is bundled in the app; every element of the look is drawn in code
- The app renders identically regardless of the system dark mode setting
- Changing the genre on a single track is reflected in iTunes on the MacBook Pro
- Changing the genre on 300 selected tracks completes in one operation without freezing the UI
- Every write is logged with old and new values
- A write against a stale Track ID is caught by the persistent ID check and does not modify the wrong track
- An XML reload never blocks reads; the API keeps answering while the new file is parsed
- A timed-out write is logged as unknown, and a later read shows whether it landed
- The daemon survives an iTunes restart and reconnects without a manual restart
- Stopping and starting the LaunchAgent restores service with no manual steps

## 12. Notes for whoever builds this

Ask before adding a dependency. The constraint that the daemon must run on Mojave with the Python standard library only is deliberate and not negotiable without a conversation. The client app has no such constraint, but keep third party packages out of it too unless there is a strong reason.

Do not substitute SwiftUI for AppKit, and do not substitute a web view for native drawing. Both would make the Aqua work harder, not easier.

If something in this spec turns out to be wrong about how iTunes 12.9.5 actually behaves, stop and say so instead of working around it. I would rather redesign than inherit a workaround I do not understand.
