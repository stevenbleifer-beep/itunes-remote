# iTunes Remote

Remote control for the iTunes library on the 2012 MacBook Pro (Mojave, iTunes
12.9.5), driven from the MacBook Air, in the look of iTunes 10. Two parts:

- `daemon/` — Python 3.13, standard library only, runs on the MacBook Pro.
  Reads come from the library XML; every write and every playback command goes
  through iTunes itself over AppleScript. Nothing touches the files on disk.
- `client/` — native AppKit app for the Air. Every control is drawn in code.

The specification is `SPEC.md`; the current state, run recipes and the list of
verified traps are in `HANDOFF.md`.

## What it does

- Browse the whole library (95,521 tracks) and every playlist, with the
  genre/artist/album column browser, search, and sortable columns.
- Cover Flow across 11,026 albums, with a view switcher.
- Play, pause, next, previous, seek, volume, shuffle, repeat, and an AirPlay
  output picker, all acting on the MacBook Pro. Audio never leaves it.
- Get Info for one track or a whole selection; bulk genre edits of hundreds of
  tracks in one operation, each write verified by persistent ID and logged
  with old and new values.
- Create playlists, add and remove tracks.
- Album art for the playing or selected track.
- iPod classic: shows in the sidebar with free space; Sync and Eject.

## Daemon on the MacBook Pro

```
cd ~/iTunesRemote/daemon
./setup.sh          # installs the LaunchAgent, then runs check.py
python3 check.py    # pass/fail for everything that can break
./probe_ipod.sh     # re-run the iPod sync probe after an iTunes update
```

Config: `~/Library/Application Support/iTunesRemote/config.json` (host, port,
token). Logs: `~/Library/Logs/iTunesRemote/daemon.log` and `writes.log`.
Every request needs `Authorization: Bearer <token>`.

Tests, from `daemon/`: `python3 -m unittest discover`.

## Client on the Air

```
cd client && ./build.sh
open "build/iTunes Remote.app"
```

First launch asks for the daemon's host, port and token (File > Connect…).
Command-I opens Get Info; space toggles playback; in Cover Flow the arrow keys,
a trackpad swipe, a pinch, or typing a letter move through the albums.

## API

```
GET  /api/library                       counts, XML write time, iTunes version
GET  /api/tracks?q=&genre=&artist=&album=&playlist=&offset=&limit=&compact=1
GET  /api/tracks/{id}                   GET /api/tracks/{id}/artwork
GET  /api/genres  /api/artists  /api/albums  /api/albumlist   (same filters)
GET  /api/playlists                     GET /api/playlists/{id}/tracks
PATCH /api/tracks                       { ids: [...], fields: { genre: "..." } }
POST /api/playlists                     POST/DELETE /api/playlists/{id}/tracks
GET  /api/player                        POST /api/player/{play|pause|playpause|next|previous|stop}
POST /api/player/{volume|position|shuffle|repeat}
GET  /api/outputs                       POST /api/outputs { names: [...] }
GET  /api/sources                       POST /api/sources/{name}/{sync|eject}
GET  /api/itunes                        POST /api/itunes/launch
```

Persistent IDs are the only track identifiers on the wire.

## Measured on the real library

| XML | 163 MB, 102,354 entries, 95,521 audio tracks served |
| Parse | 23 s on the 2012 i7 (5 s on the Air), ~370 MB resident |
| Any read | under 50 ms; whole library in compact form 1.15 s / 13.6 MB |
| One AppleScript call | about 0.2 s of process spawn |
| Bulk genre edit | 173 ms per track, mostly iTunes rewriting file tags |
