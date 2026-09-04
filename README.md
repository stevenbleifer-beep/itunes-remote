# iTunes Remote

A remote for a Mac that still runs iTunes 12: the whole library, playlists,
album art, Cover Flow, the iPod sync, and the speakers, from another Mac on
the same network or from anywhere over Tailscale — in the look of iTunes 10.
A Playlist Curator builds and edits playlists with a language model that
runs on the remote Mac itself.

The write-up: https://www.stevenbleifer.com/itunes-remote.html — and how it
works inside: https://www.stevenbleifer.com/itunes-remote-internals.html

## Two halves

- `daemon/` — Python 3, runs on the iTunes Mac as a LaunchAgent. Reads the
  library from iTunes' XML, drives iTunes through AppleScript, serves a small
  HTTP API with a bearer token, advertises itself with Bonjour.
- `client/` — a native AppKit app (Swift, no dependencies), built by
  `client/build.sh`. Talks to the daemon; runs the curator through Ollama.

## Install from the download

1. iTunes Mac: copy the `Daemon` folder anywhere and double-click
   `Install iTunes Remote Daemon.command`. It needs Python 3 from python.org
   (it opens the page if Python is missing), starts the daemon, and prints a
   six-digit pairing code. Reruns are safe and reprint the code.
2. Remote Mac: open iTunes Remote. The setup assistant finds the other Mac,
   asks for the code, and offers Tailscale (away from home) and Ollama (the
   curator) as optional steps. File ▸ Set Up iTunes Remote… runs it again.

## Build from source

    cd client && ./build.sh            # build/iTunes Remote.app, ad-hoc signed
    ./build.sh --install               # replace the copy in /Applications
    ./package.sh                       # the disk image, in build/dist

Signing and notarizing: `ITR_SIGN_IDENTITY="Developer ID Application: …"`
and `ITR_NOTARY_PROFILE=<notarytool keychain profile>` on `package.sh`.

## Requirements

- iTunes Mac: macOS with iTunes 12 (tested on Mojave 10.14.6 with 12.9.5),
  Python 3.9+, and "Share iTunes Library XML with other applications" on.
  The Music app on Catalina and later is not supported: it does not write
  the XML the daemon reads.
- Remote Mac: macOS 13 or later. Tailscale and Ollama optional.

`HANDOFF.md` and `SPEC.md` hold the working notes, measured behaviour of
iTunes, and the traps found along the way.
