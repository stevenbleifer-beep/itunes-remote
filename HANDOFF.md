# Handoff, 2026-09-02 late evening

Read SPEC.md first. It has been revised several times today and is the
authority. This file is the state of play and the traps that are not in it.

## Where things stand

| Milestone | State |
|---|---|
| 1 Daemon read path | Done. Verified on the MacBook Pro. 23 s to parse the real XML, reads under 50 ms, full compact library in 1.15 s / 13.6 MB. |
| 2 Gel button | Done, signed off by Steven. Tiger style; spec now says tone it down to Snow Leopard style during polish. |
| 3 Read-only client | Done, accepted. Screenshot in the conversation looked right after the switch to the iTunes 10 look. |
| 4 Playback, AirPlay, artwork | **In progress.** Daemon side deployed and mostly tested. Client side half written, not yet compiled. See below. |
| 5-9 | Not started. 7a Cover Flow was added to the spec today at Steven's request. |

Git: the repo has never been committed. Everything is on disk and staged
from an earlier `git add -A`; newer files are untracked. Commit when Steven
asks.

## The machines

- MacBook Pro (daemon host): `ssh -i ~/.ssh/id_ed25519_mbp2012 stevenbleifer@Stevens-MacBook-Pro.local`. Python 3.13.15 at `/usr/local/bin/python3` (installed today). iTunes 12.9.5.
- Daemon lives at `~/iTunesRemote/daemon` on the MBP, deployed by rsync from `daemon/` here. Config at `~/Library/Application Support/iTunesRemote/config.json`; token `<the token is in config.json on the MacBook Pro>`; port 8765. Logs in `~/Library/Logs/iTunesRemote/daemon.log`.
- It is running under **nohup from an SSH session, not a LaunchAgent yet.** Restart recipe (the `< /dev/null` matters, without it the ssh command never returns):

  ```
  ssh -i ~/.ssh/id_ed25519_mbp2012 stevenbleifer@Stevens-MacBook-Pro.local 'pkill -f "itunes_remote$"; sleep 1; cd ~/iTunesRemote/daemon && (nohup /usr/local/bin/python3 -m itunes_remote > ~/Library/Logs/iTunesRemote-nohup.out 2>&1 < /dev/null &)'
  ```

  It takes about 25 s to come up. Because it was started from SSH, TCC Automation attribution is sshd's; the LaunchAgent install and the "Python" Automation prompt over Screen Sharing (SPEC section 9) are still to do.
- **Talk to it by IPv4 address, `http://<lan-ip>:8765`.** The `.local` name also resolves to an IPv6 ULA address, and curl with a short timeout hangs on it. `<bridge-ip>` is a Thunderbolt Bridge to the same machine.
- Client dev loop on the Air, from `client/`: `./build.sh` then
  `"build/iTunes Remote.app/Contents/MacOS/iTunesRemote" --host <lan-ip> --token <token>`.
  Screenshot without screen-recording permission:
  `W=$(./build/windowid "iTunes Remote" | head -1 | cut -d' ' -f1); screencapture -x -o -l $W out.png`.
  The `--snapshot` cacheDisplay path renders table bodies black on macOS 26; use the live capture.
- The GelButtonTest harness is `client/build-geltest.sh`.

## Open items in milestone 4, in order

1. **`daemon/scripts/player_state.applescript` fails to compile**: "Expected expression but found “st”" at the `set st to "stopped"` line. `st` is evidently a term in iTunes' dictionary, same trap as `missing` and `removed` (see memory). Rename the variable, redeploy, then `GET /api/player` should work.
2. **Two artwork 404s to investigate**: an MP3 (`036FEA1D553917B6`, Metallica "One") and a WAV (`E36AB621A1C1EA7A`) both returned 404 in about 0.35 s, meaning the file parser found nothing and the AppleScript fallback (`artwork_export`) also returned "none" or failed quietly (failures are logged at INFO in daemon.log). Check whether those tracks really have no art in iTunes before suspecting `artwork.py`'s ID3 parser. AAC and ALAC artwork work (PNG 204 KB in 70 ms, JPEG 63 KB in 40 ms) and ETag/304 works.
3. **Nothing audible has been tested.** `POST /api/player/play` with a track, `next`, `previous`, volume, and position are untested because they would play through Steven's receiver. Tell him before the first play test, or ask him to try it.
4. **Client work remaining for milestone 4**, all in `client/Sources`:
   - `App/PlayerController.swift` and the player methods in `API/APIClient.swift` and `API/Models.swift` are written but have never been compiled.
   - `Aqua/AquaChrome.swift` `AquaDisplayPanel` still only shows two text lines. It needs the playing mode: bold title, "artist — album", a scrubber with elapsed and remaining times, drag to seek (call `PlayerController.seek`). Use `displayPosition` for smooth motion between one-second polls.
   - `App/MainWindowController.swift`: wire `previousButton` / `playButton` / `nextButton` / `volumeSlider` to the PlayerController; flip the play glyph to `.pause` while playing; double-click on the track table plays the row (pass the playlist persistent ID when the source is a playlist); space bar toggles play/pause.
   - AirPlay picker: a small drawn button with the AirPlay glyph right of the volume slider; click opens an NSMenu of `PlayerController.outputs` with checkmarks, toggling via `toggleOutput`. Use `attributedTitle` with Lucida Grande so the menu is not in San Francisco. Tint the glyph blue when a non-Computer device is selected.
   - Artwork pane at the bottom of the sidebar, iTunes 10 style: a square image with a 1 px border under a small embossed header reading "Now Playing" or "Selected Item". Fetch via `APIClient.artwork(for:)`, cache in an NSCache, show a drawn placeholder when nil.
   - Add `AquaVolumeSlider.isDragging` so polls do not fight the user's drag.
5. Then Cover Flow (SPEC 7a). It needs a per-album cover endpoint on the daemon (`GET /api/artwork?artist=&album=`, first track in the album with art), which is not written yet.

## Facts learned today that changed the spec

- The AppleScript `id` of a track is **not** the XML Track ID (which is `database ID`). `track id N of library playlist 1` fails. But `whose persistent ID is` is fast: about 0.2 s per call, 75 ms per lookup when batched in one script. The daemon looks everything up by persistent ID. A 300-track batch will take roughly 20 to 25 s; milestone 6 should try `whose persistent ID is in {...}`.
- iTunes 12.9.5 exposes `AirPlay device` objects. `outputs_list` and `outputs_set` scripts work (tested by setting Computer, which was already selected). `get name of current AirPlay devices` errors; iterate devices and read `selected` instead.
- `artworks` of a track and `raw data of artwork 1` work; the bytes are the original PNG or JPEG. Sniff the type from the bytes.
- Reload of the XML on the Air's Python held reads to about 1 s worst case; the same on the MBP is untested.

## Things Steven cares about

- Never write to library files directly; every mutation goes through iTunes. He asked why and agreed with the reasoning (database is the truth, iTunes moves files, one logged write path).
- He wanted the look changed from Tiger metal to iTunes 10 after seeing the first render. He signs off on visuals from screenshots; send them with SendUserFile.
- He asked for the feature list and wants Cover Flow "as much like iTunes 10 as possible with some modern niceties." That phrase is in SPEC 7a.
