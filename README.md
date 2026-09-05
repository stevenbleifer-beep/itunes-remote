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

## Editing tags and artwork

Get Info (⌘I) on any selection edits the tags iTunes lets a script set:
name, artist, album artist, album, composer, genre, year, track and disc
numbers, the compilation flag. The sheet also carries the cover: drop a
picture on it or click Choose…, and OK writes it to every selected song
(so select an album to re-cover the album); Remove takes it off. Pictures
are sent as JPEG no larger than 1400 px a side, and every write goes
through iTunes itself, never to the files behind its back.

## More of what iTunes did, and some it did not

- **Lyrics.** Get Info on one song has an Info | Lyrics switch; the
  lyrics are read from iTunes when the sheet opens (they are not in the
  library XML) and written back if you change them.
- **Last Played column**, from the XML's play date, beside Plays and Date
  Added. **Bit rate** rides along in the track rows for the next item.
- **Duplicates**, under LIBRARY in the sidebar (View ▸ Show Duplicates
  turns it off): songs with the same title and artist within two seconds
  of the same length, grouped, the copy worth keeping first (best bit
  rate, then rated, then most played) and the extras in grey. The status
  line says how many groups, how many extras, and how much space.
- **Find Missing Artwork…** (File menu): every album with no cover, and a
  Find Cover button that looks it up in the iTunes Store's catalogue and
  writes the picture to the album's songs. Find All walks the list and
  takes a cover only when artist and album names agree exactly. This is
  the one feature that talks to something other than the paired Mac: the
  artist and album names go to Apple's search service, and the window
  says so. You can also drop your own picture on the well.
- **More Like This**, on the track context menu, and **Make a Playlist Like
  This…** on a sidebar playlist: the curator, seeded with the selection
  instead of a description. The seed songs' embeddings pull the search
  toward them and their artists join the plan; the songs themselves stay
  off the list. The curator page and its conversation are unchanged —
  this is another way in, and you can still say what to change.
- **Syncs show on the display whoever started them.** The daemon watches
  the iPod's disk write counter, so a sync iTunes starts on its own (the
  iPod plugged in, or a synced playlist changed) appears on the LCD with
  the bytes copied so far, not only the ones started from the app.
- **Apply is safe to cancel.** The sync playlist is built in a staging
  playlist ("… (writing)") and moved into the real one in a single step at
  the end, so iTunes never sees a half-written list (it syncs a connected
  iPod as soon as a synced playlist changes, which would have stripped the
  iPod). A Cancel button beside Apply stops the build and throws the
  staging away; a second Apply while one runs is refused instead of
  starting over; and the device page does not try to read the iPod while
  the rebuild holds iTunes, which used to time out and re-enable Apply.
- **Shuffle is an order you can see.** Turning shuffle on, or starting a
  list with it on, decides the whole shuffled order there and then, with
  the current song first; Next and Previous walk it, Up Next shows what is
  coming under "Continuing from … (shuffled)", and playing something from
  the panel moves the shuffle along to it. Repeat All deals a new order
  when the round ends.
- **The app owns the queue, always.** Every song is started from the
  library, never "inside" a playlist, so iTunes holds a one-item queue and
  the app decides what follows; and if iTunes ever wanders off to a song
  of its own choosing, the app notices on the next poll and plays the
  right next one.
- **Play with nothing playing starts the list on screen** — the selected
  song, or the first (a random one with shuffle on) — instead of handing
  the click to iTunes, whose queue was whatever it last had and, with its
  own shuffle on, a random song out of it.
- **Up Next survives a relaunch.**
- **Find iPod…** (Controls menu, and a button on the page of a device
  iTunes has not opened): the daemon looks at the USB bus afresh and at
  what iTunes has open, and says which of four states the iPod is in —
  not plugged in; open in iTunes; plugged in while the other Mac's
  **screen is locked**, which is the usual case: macOS refuses to mount a
  disk plugged in while the screen is locked and ejects it, so the iPod
  says Connected, then Ejecting (unlock that Mac and plug the iPod in
  again — or, once and for all, run
  `sudo defaults write /Library/Preferences/SystemConfiguration/autodiskmount AutomountDisksWithoutUserLogin -bool true`
  there and reboot, after which disks mount behind the lock screen); or
  on the bus with iTunes ignoring it, for which it offers a restart of
  iTunes and waits up to a minute.
- **Notifications** when the song changes and the window is out of sight
  (app in the background, window hidden or minimised, mini player up):
  title, artist, album, and the cover. Controls ▸ Notify on Song Change
  turns them off; the first one asks macOS for permission.
- The daemon's token now lives in the login keychain rather than the
  preferences file (a signed build only; an ad-hoc development build
  stays on `--token` or UserDefaults, so neither ever prompts about the
  other's keychain item). Messages name the paired Mac by its own name,
  learned at pairing, instead of "the MacBook Pro".

## Two looks

**View ▸ Appearance** switches between **Classic iTunes 10** — Lucida
Grande, brushed gradients, gel buttons, the green LCD — and **Modern
Glass**: the system font, flat translucent bars with the desktop blurred
behind them, the transport buttons and the display on the system's glass
(macOS 26's glass effect, a translucent panel on older systems), rounded
pill selections in the accent colour, overlay scrollers. Every control is
still drawn by the app; each one asks the theme at draw time. The choice
is read once at launch, so the switch relaunches the app. The modern look
follows the system's light or dark setting; every colour it draws with is
dynamic, and the fixed greys of the classic drawing are turned over for it
in the dark. Classic is always light, as iTunes 10 was.

## Two libraries: iTunes over there, Apple Music here

**File ▸ Library** switches the app between iTunes on the other Mac and
the Apple Music library in Music.app on this one. They are never mixed:
each has its own connection and token, its own Up Next, its own curator
index, lessons and training (under `Application Support/iTunes Remote`
and `…/iTunes Remote/Apple Music`), and switching quits and reopens the
app so nothing carries across. The Apple Music side needs no pairing —
the app bundles the daemon and its library reader (`musiclibdump`,
which reads Music's library through the iTunesLibrary framework into
the same shape as iTunes' XML) and installs them as a LaunchAgent on
first use. What works there: everything but the iPod. Music syncs
devices through the Finder and exposes none of it, so the device page,
sync plan, Find iPod and the restart command are gone; songs that are
Apple Music streams rather than files have no local playback or
file-based artwork. The same source also builds a stand-alone "Apple
Music Remote" (`ITR_VARIANT=music`), which is the same thing without the
switch.

## On the Apple Music side: the catalogue, and deleting

With the Apple Music library active, the search field's drop-down searches
**Apple Music itself** — songs and albums you do not have — while the list
underneath keeps filtering the library you do. Pick a result and a menu
offers Play on Apple Music, Add to Library (or Add Album to Library), Add
to Playlist ▸ one of your playlists, and New Playlist with This…. The
lookups and adds go through MusicKit, signed with a token it makes for
this app; that needs the app's identifier
(`local.stevenbleifer.itunesremote`) to have the **MusicKit** service
enabled in the Apple Developer account (Certificates, Identifiers &
Profiles ▸ Identifiers ▸ App Services), an Apple Music subscription on the
Mac, and a one-time "may use Apple Music" permission. Adds show up in the
app once Music has written them into its library, usually within a minute.

**Controls ▸ Identify What's Playing…** (⌘⇧I) listens to the microphone
for twelve seconds and asks Shazam what it heard — nothing is recorded,
only a signature of the sound is sent. The answer offers Find in Library,
and on the Apple Music side Add to Library and Play on Apple Music. It
needs the ShazamKit service on the app's identifier and a one-time
microphone permission.

**Delete from Library…** on the track menu (both libraries) removes songs
from the library on the far end and from every playlist. The files stay
where they are. There is no undo, so it asks first.

Music does not have to be open. Reading the library goes through its
library file, and playing files on this Mac never touches it. Playing
through Music, or changing anything in it, does — and the daemon launches
it hidden, in the background, when that happens.

## Turning the AI off

**View ▸ AI Features** is one switch for everything that runs a model: the
Playlist Curator section, More Like This and Make a Playlist Like This…,
Controls ▸ Train Curator on My Edits…, and the bundled model server,
which is stopped so nothing runs in the background. Off, none of it shows.
Nothing on disk is touched — the search index, the saved lessons and any
trained picker stay where they are — and turning it back on brings it all
back as it was. Find Missing Artwork… is not AI and stays.

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
  adapter on those (base: Qwen 2.5 7B Instruct, which both trains at
  full length in 24 GB and imports into Ollama), fuses it, imports it as
  `itunes-curator` and points the app at it. **Controls ▸ Train Curator on
  My Edits…** runs the same script from inside the app: it shows how many
  turns are on file, asks before fetching anything (Python 3.12 and the
  training library via `uv`, then the base model), shows progress, and
  can stop the run or go back to the stock picker. It wants a few hundred
  saved playlists to be worth running and takes several hours on an
  M-series Mac; under 40 it offers to train anyway, for trying it out.

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
