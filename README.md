# iTunes Remote

A remote control for iTunes 12.9.5 running on a headless 2012 MacBook Pro,
driven from a modern Mac. Two pieces:

- **`daemon/`** — Python 3, no dependencies outside the standard library. Parses
  the iTunes XML library into memory, drives iTunes through AppleScript, and
  serves a small JSON HTTP API behind a bearer token. Runs as a LaunchAgent.
- **`client/`** — a native AppKit app for the modern Mac, drawn to look like
  iTunes 10: the Aqua chrome, the green LCD, the column browser, List / Album
  List / Grid / Cover Flow, a mini player, and the iTunes 12 device pages.

Everything the app changes goes through iTunes itself. Nothing writes to the
library files on disk.

## What it does

- Browse a 94,000-track library: column browser, search, all four views,
  Recently Added, playlists.
- Play through iTunes on the old Mac, through an AirPlay speaker, or stream
  the file and play it on the Mac you are sitting at.
- Edit tags, ratings and the checkbox column; create, rename and delete
  playlists; drag tracks and albums onto them.
- Read the iPod: capacity, categories, playlists, what actually reached it.
- Drive the iPod's sync selection. iTunes keeps its own selection somewhere
  nothing outside iTunes can read, so the app holds a selection of its own and
  projects it onto a playlist the iPod syncs — see `SPEC.md`.
- Surface the modal dialogs iTunes raises on a machine nobody is sitting at,
  and dismiss them remotely.

## Running it

The daemon needs a config with a bearer token:

    python3 -m itunes_remote --init-config
    python3 -m itunes_remote

`daemon/setup.sh` installs it as a LaunchAgent, and `daemon/check.py` verifies
the machine (Automation permission, iTunes version, XML path). The client is
built with `client/build.sh`; `--install` puts it in `/Applications`.

`SPEC.md` is the authority on behaviour and carries dated revision notes.
`HANDOFF.md` is the state of play, the machine setup, and the traps that are
not in the spec — read it before changing anything.
