# iTunes Remote

Remote control for the iTunes library on the 2012 MacBook Pro (Mojave, iTunes
12.9.5), driven from the MacBook Air. Two parts:

- `daemon/` — Python 3.13, standard library only. Runs on the MacBook Pro.
  Reads come from the library XML; writes and playback go through AppleScript.
- `client/` — native AppKit app in the vintage Aqua style. Runs on the Air.

The full specification is in `SPEC.md`.

## Daemon quick start

Requires Python 3.13 from python.org on the MacBook Pro (the last python.org
installer that supports Mojave). Nothing else.

```
cd daemon
python3 -m itunes_remote --init-config      # writes config + prints the token
python3 -m itunes_remote                    # loads the XML, serves on :8765
```

Config lives at `~/Library/Application Support/iTunesRemote/config.json`.
Every request needs the token, as `Authorization: Bearer <token>`.

For development on the Air, point it at a copy of the XML:

```
python3 -m itunes_remote --config dev-config.json --xml /path/to/copy.xml --no-log-file
```

## Read API (milestone 1)

```
GET /api/library                       counts, XML write time, load time
GET /api/tracks?q=&genre=&artist=&album=&playlist=&offset=&limit=
GET /api/tracks/{persistentId}
GET /api/genres?q=&artist=&album=      distinct values with counts, over the same filters
GET /api/artists?q=&genre=&album=
GET /api/albums?q=&genre=&artist=
GET /api/playlists
GET /api/playlists/{persistentId}/tracks?q=&offset=&limit=
```

Filters compose, so the genre/artist/album browser panes are one call each.
`q` matches every whitespace-separated term against name, artist, album, and
album artist, case-insensitively. Only audio file tracks are served; cloud
entries, video, and podcasts are dropped at load.

## Measured on the real XML (2026-09-02, copy on the M5 Air)

| Measure | Value |
|---|---|
| XML size | 163 MB, 102,354 entries |
| Audio file tracks served | 95,521 |
| Parse time | ~5 s on the Air; expect 20-30 s on the 2012 i7 |
| Resident memory after load | ~480 MB |
| Any read endpoint | under 50 ms |
| Worst read latency during a background reload | ~1 s on the Air |

The reload runs on a background thread, but parsing holds the interpreter
lock in bursts, so reads slow down while it happens. They do not stop. If
this is noticeable on the MacBook Pro, the fix is to parse in a child
process and hand back only the slim track records.
