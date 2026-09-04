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
    ./fetch-ollama.sh                  # once: the bundled model server into Vendor/
    ./package.sh                       # the disk image, in build/dist

Signing and notarizing: `ITR_SIGN_IDENTITY="Developer ID Application: …"`
and `ITR_NOTARY_PROFILE=<notarytool keychain profile>` on `package.sh`.

## Requirements

- iTunes Mac: macOS with iTunes 12 (tested on Mojave 10.14.6 with 12.9.5),
  Python 3.9+, and "Share iTunes Library XML with other applications" on.
  The Music app on Catalina and later is not supported: it does not write
  the XML the daemon reads.
- Remote Mac: Apple Silicon, macOS 13 or later. Tailscale optional. The
  model server for the curator is built in (Ollama, Apple Silicon build);
  an Ollama app already on the Mac is used instead when it is running.

## The curator learns

Three things make it better the more it is used, none of which sends
anything off the Mac:

- **Your edits.** Every song you delete from a curated list, every piece
  of feedback, every list you save is kept in
  `~/Library/Application Support/iTunes Remote/curator/memory.json`. On a
  request like an old one (found by embedding, so "songs from the
  nineties" reaches a lesson about "90s anthems") the songs you took out
  are not offered again, and the model is told what you said last time.
  A song taken out of any two lists is never offered again.
- **Your plays.** Play counts and ratings become a per-artist and
  per-genre profile; search leans a little toward what you actually
  play, artists you play a lot are marked ♥ for the model, and one-star
  songs are never candidates.
- **A fine-tune, when there is enough data.** Saving a list also writes
  the turns that led to it to `curator/training.jsonl`, in the chat
  format `mlx-lm` reads. `client/finetune/finetune.sh` trains a LoRA
  adapter on those, fuses it, imports the result into Ollama as
  `itunes-curator` and points the app at it. It wants a few hundred saved
  playlists to be worth running, refuses under 40 without `--force`, takes
  an hour or two on an M-series Mac, and `--revert` goes back to the
  stock picker.

## Built with Claude Code

Every line here was written with [Claude Code](https://claude.com/claude-code),
Anthropic's terminal agent, working against the real library on the real
machines. Models used, in order of how much of the work they did:

| Model | Role |
|---|---|
| Claude Opus 5 | the daemon, the AppKit client, iPod sync, Cover Flow, most of milestones 1–9 (2–3 September 2026) |
| Claude Fable 5.1 | Grid view, mini player, Up Next, search, remote access, album art, the Playlist Curator, setup assistant, embedded Ollama, signing (3–4 September 2026) |
| Claude Opus 4.8 | early client work and screenshots |
| Claude Opus 4.7 | the first spec pass |

Through 3 September that was 425 million tokens across 1,079 responses for
13,781 lines that survived; the write-up at
https://www.stevenbleifer.com/itunes-remote-internals.html has the table
and the story behind the number. The curator itself runs on open models
through Ollama: `qwen3.5:4b` (or `gemma4:12b` / `gemma4:26b` by choice)
picks the songs, `embeddinggemma:300m` indexes the library for search.

`HANDOFF.md` and `SPEC.md` hold the working notes, measured behaviour of
iTunes, and the traps found along the way.
