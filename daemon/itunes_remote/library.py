"""In-memory copy of the iTunes library, loaded from the XML plist.

Reads never touch iTunes. The XML is parsed once at startup and again, in a
background thread, whenever iTunes rewrites it. Writes made through the
daemon are patched into the in-memory copy immediately and journaled, so a
reload of a stale XML does not undo them.
"""

import logging
import os
import plistlib
import re
import threading
import time
import unicodedata
from urllib.parse import unquote, urlsplit
from datetime import datetime, timezone

log = logging.getLogger("itunes_remote.library")


def fold(s):
    """Normalise for case-insensitive comparison. XML is NFC; be safe anyway."""
    return unicodedata.normalize("NFC", s or "").casefold()


# iTunes' browser merges spellings that differ only in accents or in the shape
# of a quote or dash: "Motorhead" and "Motörhead" are one artist to it, and so
# are "Roadkill Rising..." and "Roadkill Rising…". Measured against iTunes
# 12.9.5's own column browser on the real library, 2026-09-03.
_SPACES = re.compile(r"\s+")

_PUNCT = {
    "\u2019": "'", "\u2018": "'", "\u201c": '"', "\u201d": '"',
    "\u2013": "-", "\u2014": "-", "\u2026": "...", "\u00a0": " ",
}


def browse_key(s):
    """The key iTunes groups a browser row under. Accent- and punctuation-
    insensitive, whitespace collapsed. Only for grouping; never displayed."""
    s = (s or "").strip()
    for bad, good in _PUNCT.items():
        if bad in s:
            s = s.replace(bad, good)
    s = _SPACES.sub(" ", s)
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return unicodedata.normalize("NFC", s).casefold()


def _iso(dt):
    if dt is None:
        return None
    return dt.replace(tzinfo=timezone.utc).isoformat()


class Track(object):
    """One audio file track. Slots keep ~100k of these small."""

    __slots__ = (
        "persistent_id", "track_id", "name", "artist", "album", "album_artist",
        "genre", "composer", "year", "track_number", "track_count",
        "disc_number", "disc_count", "total_time", "kind", "size", "bit_rate",
        "compilation", "enabled", "rating", "play_count", "grouping", "bpm",
        "date_added", "date_modified", "location", "artwork_count", "search", "sort_key",
        "sort_name", "sort_artist", "sort_album", "sort_album_artist",
        "browse_artist", "group_keys", "artist_display_key",
    )

    # Fields the client may edit through PATCH, mapped to the AppleScript
    # property names used later. Kept here so the read side and the write
    # side agree on what is editable.
    EDITABLE = {
        "name": "name",
        "artist": "artist",
        "album": "album",
        "album_artist": "album artist",
        "genre": "genre",
        "composer": "composer",
        "grouping": "grouping",
        "bpm": "bpm",
        "year": "year",
        "track_number": "track number",
        "disc_number": "disc number",
        "compilation": "compilation",
        "enabled": "enabled",
        "rating": "rating",
    }

    # The subset of EDITABLE that appears in sort_key. Editing anything else,
    # genre above all, cannot change the row order, so it needs no re-sort.
    SORT_FIELDS = frozenset((
        "name", "artist", "album_artist", "album", "year", "track_number", "disc_number",
    ))

    def __init__(self, raw):
        self.persistent_id = raw["Persistent ID"]
        self.track_id = raw["Track ID"]
        # A tag holding only whitespace is blank for every purpose here:
        # grouping, sorting, the browser, and "Unknown Artist" captions.
        self.name = _text(raw.get("Name"))
        self.artist = _text(raw.get("Artist"))
        self.album = _text(raw.get("Album"))
        self.album_artist = _text(raw.get("Album Artist"))
        self.genre = _text(raw.get("Genre"))
        self.composer = _text(raw.get("Composer"))
        self.grouping = _text(raw.get("Grouping"))
        self.bpm = raw.get("BPM") or 0
        self.year = raw.get("Year")
        self.track_number = raw.get("Track Number")
        self.track_count = raw.get("Track Count")
        self.disc_number = raw.get("Disc Number")
        self.disc_count = raw.get("Disc Count")
        self.total_time = raw.get("Total Time")
        self.kind = raw.get("Kind", "")
        self.size = raw.get("Size")
        self.bit_rate = raw.get("Bit Rate")
        self.compilation = bool(raw.get("Compilation", False))
        self.enabled = not raw.get("Disabled", False)   # the track checkbox
        self.rating = raw.get("Rating") or 0             # 0-100, stars are 20 each
        self.play_count = raw.get("Play Count") or 0
        self.date_added = _iso(raw.get("Date Added"))
        self.date_modified = _iso(raw.get("Date Modified"))
        self.sort_name = _text(raw.get("Sort Name"))
        self.sort_artist = _text(raw.get("Sort Artist"))
        self.sort_album = _text(raw.get("Sort Album"))
        self.sort_album_artist = _text(raw.get("Sort Album Artist"))
        self.location = _posix_path(raw.get("Location"))
        self.artwork_count = raw.get("Artwork Count") or 0
        self.reindex()

    def reindex(self):
        self.search = "\x1f".join(
            fold(x) for x in (self.name, self.artist, self.album, self.album_artist)
        )
        # The name iTunes files this track under in the Artists browser: the
        # album artist if there is one, and "Compilations" for anything flagged
        # as part of a compilation, which is how iTunes gathers them.
        if self.compilation:
            self.browse_artist = COMPILATIONS
            artist_group = COMPILATIONS
        else:
            self.browse_artist = self.album_artist or self.artist
            # iTunes groups artists by the Sort field where the track has one,
            # so "Jay-Z" and "JAY Z" land on the same row when they share a
            # sort artist. Albums do NOT work this way: Sort Album is usually
            # just the title with its article stripped, and grouping on that
            # merges genuinely different albums. Both verified against iTunes.
            if self.album_artist:
                artist_group = self.sort_album_artist or self.album_artist
            else:
                artist_group = self.sort_artist or self.artist
        # Two keys for the artist, and a browser click matches either.
        #
        # The row is grouped by the Sort Artist field but labelled with the
        # display name, and iTunes fills in a sort artist for every "The X"
        # band. So the row said "The Beatles" while its key was "beatles", and
        # clicking it selected nothing: 265 of 2,905 rows were dead this way.
        self.artist_display_key = browse_key(self.browse_artist)
        self.group_keys = {
            "artist": browse_key(artist_group),
            "album": browse_key(self.album),
            "genre": browse_key(self.genre),
            "composer": browse_key(self.composer),
            "grouping": browse_key(self.grouping),
        }
        # Match iTunes: Sort fields win, and a leading article is dropped.
        if self.album_artist:
            artist = sort_form(self.album_artist, self.sort_album_artist or self.sort_artist)
        else:
            artist = sort_form(self.artist, self.sort_artist)
        self.sort_key = (
            artist == "",          # blanks sort last, as iTunes does
            artist,
            self.year or 0,
            sort_form(self.album, self.sort_album),
            self.disc_number or 0,
            self.track_number or 0,
            sort_form(self.name, self.sort_name),
        )

    def to_dict(self):
        return {
            "persistentId": self.persistent_id,
            "trackId": self.track_id,
            "name": self.name,
            "artist": self.artist,
            "album": self.album,
            "albumArtist": self.album_artist,
            "genre": self.genre,
            "composer": self.composer,
            "grouping": self.grouping,
            "bpm": self.bpm,
            "year": self.year,
            "trackNumber": self.track_number,
            "trackCount": self.track_count,
            "discNumber": self.disc_number,
            "discCount": self.disc_count,
            "totalTime": self.total_time,
            "kind": self.kind,
            "size": self.size,
            "bitRate": self.bit_rate,
            "compilation": self.compilation,
            "enabled": self.enabled,
            "rating": self.rating,
            "playCount": self.play_count,
            "dateAdded": self.date_added,
            "dateModified": self.date_modified,
        }

    def apply(self, fields):
        """Patch editable fields. Returns the old values."""
        old = {}
        for key, value in fields.items():
            if key not in self.EDITABLE:
                raise ValueError("field not editable: %s" % key)
            old[key] = getattr(self, key)
            setattr(self, key, value)
        self.reindex()
        return old


# The row iTunes files compilation tracks under in the Artists browser.
COMPILATIONS = "Compilations"


# iTunes drops a leading article when sorting, so "The Beatles" files under B.
_ARTICLES = ("the ", "a ", "an ")

# Quotation marks are ignored wherever they fall, so "Weird Al" Yankovic files
# under W and 'N Sync under N.
_QUOTES = "\"'\u2018\u2019\u201c\u201d\u00ab\u00bb"

# Names that start with a digit go after Z, as iTunes lists them. Any code
# point above every letter does; this one is private-use, so it never occurs
# in a real tag.
_DIGITS_LAST = "\uf8ff"
# And a title that is only punctuation goes after the digits.
_SYMBOLS_LAST = "\uffff"


def _plain(value):
    """Letters, digits and spaces only: punctuation, brackets and symbols are
    ignored and accents dropped, so (Sandy) Alex G sorts under S, R.E.M. as
    "rem", and Björk beside Bjork."""
    value = unicodedata.normalize("NFKD", value)
    return "".join(c for c in value
                   if (c.isalnum() or c == " ") and not unicodedata.combining(c)).strip()


def sort_form(text, override=None):
    """iTunes' sort order for one field: its Sort override if the track has
    one, otherwise the text with a leading article removed, quotes ignored,
    leading punctuation skipped, and digits after letters."""
    # Leading whitespace in a tag must not sort the row to the very top;
    # iTunes ignores it. Found on an artist tagged " Marduk".
    value = fold((override or text or "").strip())
    value = _plain("".join(c for c in value if c not in _QUOTES))
    for article in _ARTICLES:
        if value.startswith(article) and len(value) > len(article):
            value = _plain(value[len(article):])
            break
    if value and value[0].isdigit():
        return _DIGITS_LAST + value
    if not value and (override or text or "").strip():
        # Nothing but symbols — Ed Sheeran's "=" — used to sort first, on an
        # empty key. iTunes puts these after everything; so does this.
        return _SYMBOLS_LAST + fold((override or text).strip())
    return value


def _text(value):
    """Tag text with whitespace-only values collapsed to empty."""
    if not value:
        return ""
    return value if value.strip() else ""


def _posix_path(url):
    """file:///Users/x/A%20B.m4a -> /Users/x/A B.m4a (NFC)."""
    if not url or not url.startswith("file:"):
        return None
    path = unquote(urlsplit(url).path)
    return unicodedata.normalize("NFC", path)


def _is_audio_file(raw):
    if raw.get("Track Type") != "File":
        return False
    if raw.get("Podcast"):
        return False
    return "audio" in raw.get("Kind", "")


class Library(object):
    """An immutable-ish snapshot of the XML. Only `patch` mutates it."""

    def __init__(self, path):
        self.path = path
        st = os.stat(path)
        self.mtime = st.st_mtime
        self.file_size = st.st_size
        t0 = time.time()
        with open(path, "rb") as f:
            raw = plistlib.load(f)
        self.parse_seconds = round(time.time() - t0, 2)
        self.loaded_at = time.time()

        xml_date = raw.get("Date")
        self.xml_date = (
            xml_date.replace(tzinfo=timezone.utc).timestamp() if xml_date else self.mtime
        )
        self.application_version = raw.get("Application Version", "")
        self.library_persistent_id = raw.get("Library Persistent ID", "")
        self.music_folder = raw.get("Music Folder", "")

        self.tracks = {}
        self.by_track_id = {}
        self.total_entries = len(raw.get("Tracks", {}))
        for entry in raw["Tracks"].values():
            if not _is_audio_file(entry):
                continue
            t = Track(entry)
            self.tracks[t.persistent_id] = t
            self.by_track_id[t.track_id] = t.persistent_id

        self.order = sorted(self.tracks.values(), key=lambda t: t.sort_key)

        self.playlists = []
        for p in raw.get("Playlists", []):
            if p.get("Master") or "Distinguished Kind" in p:
                continue
            items = []
            for item in p.get("Playlist Items", []):
                pid = self.by_track_id.get(item.get("Track ID"))
                if pid is not None:
                    items.append(pid)
            self.playlists.append({
                "persistentId": p["Playlist Persistent ID"],
                "playlistId": p["Playlist ID"],
                "name": p.get("Name", ""),
                "smart": "Smart Info" in p,
                # Folders are playlists too, in the XML and to AppleScript;
                # a folder's items are everything in the playlists under it.
                "folder": bool(p.get("Folder")),
                "parentId": p.get("Parent Persistent ID"),
                "count": len(items),
                "items": items,
            })
        self.playlists_by_id = {p["persistentId"]: p for p in self.playlists}
        del raw
        log.info(
            "loaded %s: %d audio tracks of %d entries, %d playlists, %.1fs",
            path, len(self.tracks), self.total_entries, len(self.playlists),
            self.parse_seconds,
        )

    # -- reads ---------------------------------------------------------

    def info(self):
        return {
            "trackCount": len(self.tracks),
            "xmlEntryCount": self.total_entries,
            "playlistCount": len(self.playlists),
            "xmlPath": self.path,
            "xmlSizeBytes": self.file_size,
            "xmlWrittenAt": datetime.fromtimestamp(self.xml_date, timezone.utc).isoformat(),
            "loadedAt": datetime.fromtimestamp(self.loaded_at, timezone.utc).isoformat(),
            "parseSeconds": self.parse_seconds,
            "applicationVersion": self.application_version,
            "libraryPersistentId": self.library_persistent_id,
        }

    def _candidates(self, playlist=None, recent=0):
        """The tracks a request starts from, before any browser filter.

        `recent` cuts the set to the N newest tracks *first*, the way a smart
        playlist does. It used to be applied after the filters, which made
        Recently Added inconsistent with itself: the browser listed every
        artist in the library, and an album picked from the newest 600
        albums showed no tracks because none of them were in the newest 600
        tracks. Now every view of Recently Added is a view of one set.
        """
        if playlist is None:
            out = self.order
        else:
            p = self.playlists_by_id.get(playlist)
            if p is None:
                raise KeyError(playlist)
            out = [self.tracks[pid] for pid in p["items"]]
        if recent:
            out = sorted(out, key=lambda t: t.date_added or "", reverse=True)[:recent]
        return out

    def _filter(self, tracks, q=None, genre=None, artist=None, album=None,
                composer=None, grouping=None):
        # Browser selections are matched on the same key the browser grouped
        # by, so clicking a row selects exactly the tracks it counted.
        terms = [fold(x) for x in (q or "").split() if x]
        g = browse_key(genre) if genre is not None else None
        ar = browse_key(artist) if artist is not None else None
        al = browse_key(album) if album is not None else None
        co = browse_key(composer) if composer is not None else None
        gr = browse_key(grouping) if grouping is not None else None
        out = []
        for t in tracks:
            keys = t.group_keys
            if g is not None and keys["genre"] != g:
                continue
            if ar is not None and keys["artist"] != ar and t.artist_display_key != ar:
                continue
            if al is not None and keys["album"] != al:
                continue
            if co is not None and keys["composer"] != co:
                continue
            if gr is not None and keys["grouping"] != gr:
                continue
            if terms:
                s = t.search
                if not all(term in s for term in terms):
                    continue
            out.append(t)
        return out

    COMPACT_COLUMNS = (
        "persistentId", "name", "artist", "album", "albumArtist", "genre",
        "year", "trackNumber", "discNumber", "totalTime", "size", "compilation", "enabled",
        "rating", "playCount", "composer", "grouping", "bpm", "kind", "dateAdded",
        # iTunes' sort forms, so the client's column sorts agree with the
        # default order instead of filing "The Beatles" under T.
        "sortArtist", "sortAlbum", "sortName",
    )

    def query(self, q=None, genre=None, artist=None, album=None, composer=None,
              grouping=None, playlist=None, offset=0, limit=200, compact=False, recent=0):
        matched = self._filter(self._candidates(playlist, recent), q, genre, artist, album, composer, grouping)
        page = matched[offset:offset + limit]
        total_time = 0
        total_size = 0
        for t in matched:
            total_time += t.total_time or 0
            total_size += t.size or 0
        out = {
            "total": len(matched),
            "offset": offset,
            "limit": limit,
            "totalTime": total_time,
            "totalSize": total_size,
        }
        if compact:
            # Arrays instead of objects: the whole library in one response is
            # about a third the size, and the client decodes it much faster.
            out["columns"] = list(self.COMPACT_COLUMNS)
            out["rows"] = [
                [t.persistent_id, t.name, t.artist, t.album, t.album_artist, t.genre,
                 t.year, t.track_number, t.disc_number, t.total_time, t.size, t.compilation, t.enabled,
                 t.rating, t.play_count, t.composer, t.grouping, t.bpm, t.kind, t.date_added,
                 t.sort_key[1], t.sort_key[3], t.sort_key[6]]
                for t in page
            ]
        else:
            out["tracks"] = [t.to_dict() for t in page]
        return out

    FACET_FIELDS = ("genre", "artist", "album", "composer", "grouping")

    def facet(self, field, q=None, genre=None, artist=None, album=None,
              composer=None, grouping=None, playlist=None, recent=0):
        """Distinct values of `field` with counts, over the filtered set."""
        if field not in self.FACET_FIELDS:
            raise ValueError("not a browsable field: %s" % field)
        overrides = {"artist": "sort_album_artist", "album": "sort_album"}
        override_attr = overrides.get(field)
        counts = {}
        spellings = {}
        order = {}
        for t in self._filter(self._candidates(playlist, recent), q, genre, artist, album, composer, grouping):
            key = t.group_keys[field]
            # iTunes shows no blank row and does not count one; a track with an
            # empty tag simply appears under "All".
            if not key:
                continue
            value = t.browse_artist if field == "artist" else (getattr(t, field) or "")
            counts[key] = counts.get(key, 0) + 1
            spelling = spellings.get(key)
            if spelling is None:
                spelling = spellings[key] = {}
                override = getattr(t, override_attr) if override_attr else None
                order[key] = sort_form(value, override)
            spelling[value] = spelling.get(value, 0) + 1
        return [
            # One row can gather several spellings; show the commonest, and
            # break a tie on the text so the row name does not wander between
            # requests.
            {"name": max(sorted(spellings[k]), key=lambda v: spellings[k][v]).strip(),
             "count": counts[k]}
            for k in sorted(counts, key=lambda k: (k == "", order.get(k, k)))
        ]

    def albums(self, q=None, genre=None, artist=None, album=None, composer=None,
               grouping=None, playlist=None, recent=0):
        """One row per album, for Cover Flow, Grid and Album List.

        The cover track is the earliest track in the album that iTunes says has
        artwork, falling back to the earliest track, so the client can ask for
        exactly one image per album.
        """
        groups = {}
        for t in self._filter(self._candidates(playlist, recent), q, genre, artist, album, composer, grouping):
            display_artist = t.album_artist or t.artist
            # Same folding as the browser, so an accented spelling does not
            # split one album into two covers.
            key = (browse_key(display_artist), browse_key(t.album))
            g = groups.get(key)
            if g is None:
                g = groups[key] = {
                    "album": t.album,
                    "artist": display_artist,
                    "year": t.year,
                    "trackCount": 0,
                    "totalTime": 0,
                    "coverTrackId": None,
                    "dateAdded": None,
                    "_coverRank": None,
                    "_sortKey": (
                        sort_form(display_artist, t.sort_album_artist or t.sort_artist),
                        sort_form(t.album, t.sort_album),
                    ),
                }
            if t.date_added and (g["dateAdded"] is None or t.date_added > g["dateAdded"]):
                # The album's recency is that of its newest track.
                g["dateAdded"] = t.date_added
            g["trackCount"] += 1
            g["totalTime"] += t.total_time or 0
            if g["year"] is None and t.year:
                g["year"] = t.year
            rank = (0 if t.artwork_count else 1, t.disc_number or 0, t.track_number or 0)
            if g["_coverRank"] is None or rank < g["_coverRank"]:
                g["_coverRank"] = rank
                g["coverTrackId"] = t.persistent_id
                g["hasArtwork"] = bool(t.artwork_count)
        if recent:
            # Every album the newest tracks touch, newest first. The cut to N
            # already happened on the tracks.
            order = sorted(groups, key=lambda k: groups[k]["dateAdded"] or "", reverse=True)
        else:
            order = sorted(groups, key=lambda k: (k[0] == "", groups[k]["_sortKey"]))
        out = []
        for key in order:
            g = groups[key]
            g.pop("_coverRank", None)
            g.pop("_sortKey", None)
            g.setdefault("hasArtwork", False)
            out.append(g)
        return out

    def playlist_summaries(self):
        return [
            {k: v for k, v in p.items() if k != "items"} for p in self.playlists
        ]

    # -- writes (in-memory only; iTunes is written elsewhere) -------------

    def patch(self, persistent_id, fields):
        return self.patch_many({persistent_id: fields})[persistent_id]

    # -- playlist membership --------------------------------------------

    def playlist_create(self, persistent_id, name, parent_id=None, folder=False):
        entry = {
            "persistentId": persistent_id,
            "playlistId": None,
            "name": name,
            "smart": False,
            "folder": folder,
            "parentId": parent_id,
            "count": 0,
            "items": [],
        }
        self.playlists = sorted(self.playlists + [entry], key=lambda p: fold(p["name"]))
        self.playlists_by_id[persistent_id] = entry
        return entry

    def playlist_rename(self, playlist_id, name):
        p = self.playlists_by_id.get(playlist_id)
        if p is None:
            raise KeyError(playlist_id)
        p["name"] = name
        self.playlists.sort(key=lambda x: fold(x["name"]))
        return p

    def playlist_delete(self, playlist_id):
        p = self.playlists_by_id.pop(playlist_id, None)
        if p is None:
            raise KeyError(playlist_id)
        self.playlists = [x for x in self.playlists if x["persistentId"] != playlist_id]
        return p

    def playlist_add(self, playlist_id, track_ids):
        p = self.playlists_by_id.get(playlist_id)
        if p is None:
            raise KeyError(playlist_id)
        added = [pid for pid in track_ids if pid in self.tracks]
        p["items"] = p["items"] + added
        p["count"] = len(p["items"])
        return len(added)

    def playlist_remove(self, playlist_id, track_ids):
        p = self.playlists_by_id.get(playlist_id)
        if p is None:
            raise KeyError(playlist_id)
        drop = set(track_ids)
        before = len(p["items"])
        p["items"] = [pid for pid in p["items"] if pid not in drop]
        p["count"] = len(p["items"])
        return before - len(p["items"])

    def patch_many(self, patches):
        """Applies {persistent_id: fields} and returns {persistent_id: old fields}.

        Two rules matter here, and both exist because readers run concurrently
        on other threads without taking a lock:

        1. Never sort `order` in place. CPython empties a list for the duration
           of `list.sort`, so a reader iterating it mid-sort sees no tracks at
           all. Build a new list with `sorted` and rebind the attribute, which
           is atomic; a reader either sees the whole old list or the whole new
           one.
        2. Validate every field before mutating anything, so a bad field name
           partway through a 300-track batch cannot leave it half applied.
        """
        targets = {}
        for pid, fields in patches.items():
            track = self.tracks.get(pid)
            if track is None:
                raise KeyError(pid)
            for key in fields:
                if key not in Track.EDITABLE:
                    raise ValueError("field not editable: %s" % key)
            targets[pid] = track

        old = {}
        resort = False
        for pid, fields in patches.items():
            old[pid] = targets[pid].apply(fields)
            if not resort and not Track.SORT_FIELDS.isdisjoint(fields):
                resort = True
        if resort:
            self.order = sorted(self.order, key=lambda t: t.sort_key)
        return old


class LibraryStore(object):
    """Owns the current Library, reloads it in the background, and journals
    patches so they survive a reload of an XML that predates them."""

    def __init__(self, path, poll_interval=5.0):
        self.path = path
        self.poll_interval = poll_interval
        self._lock = threading.Lock()
        self._reload_lock = threading.Lock()   # one reparse at a time
        self._lib = None
        self._journal = []  # (timestamp, persistent_id, fields)
        self._playlist_journal = []  # (timestamp, op, playlist_id, track_ids, name, extra)
        self._reloading = False
        self._stop = threading.Event()
        self._thread = None
        self.last_error = None

    @property
    def lib(self):
        return self._lib

    def load(self):
        """Blocking initial load. Raises if the XML is missing or unreadable."""
        if not os.path.exists(self.path):
            raise FileNotFoundError(
                "%s does not exist. In iTunes, open Preferences > Advanced and "
                "enable 'Share iTunes Library XML with other applications', "
                "then restart the daemon." % self.path
            )
        self._lib = Library(self.path)

    def start_watcher(self):
        self._thread = threading.Thread(target=self._watch, name="xml-watcher", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()

    def _watch(self):
        pending_mtime = None
        pending_size = None
        while not self._stop.wait(self.poll_interval):
            try:
                st = os.stat(self.path)
            except OSError as e:
                self.last_error = str(e)
                continue
            if st.st_mtime == self._lib.mtime and st.st_size == self._lib.file_size:
                pending_mtime = None
                continue
            # Wait for the file to sit still for one poll before parsing, so a
            # half-written XML is not picked up.
            if pending_mtime != st.st_mtime or pending_size != st.st_size:
                pending_mtime, pending_size = st.st_mtime, st.st_size
                continue
            if self._reload_lock.acquire(blocking=False):
                try:
                    self._reload()
                finally:
                    self._reload_lock.release()
            pending_mtime = None

    def check_now(self):
        """The Refresh button: look at the XML this instant and reparse if it
        differs from what was read, without the watcher's wait for it to sit
        still. Returns True when a reload happened."""
        try:
            st = os.stat(self.path)
        except OSError as e:
            self.last_error = str(e)
            return False
        if st.st_mtime == self._lib.mtime and st.st_size == self._lib.file_size:
            return False
        if not self._reload_lock.acquire(blocking=False):
            return False   # the watcher is already on it
        try:
            self._reload()
        finally:
            self._reload_lock.release()
        return True

    def _reload(self):
        self._reloading = True
        try:
            new = Library(self.path)
        except Exception as e:  # half-written file, or worse
            self.last_error = "reload failed: %s" % e
            log.warning(self.last_error)
            self._reloading = False
            return
        with self._lock:
            # Replay only patches newer than the XML we just parsed. `new` is
            # not published until the assignment below, so nothing reads it yet,
            # but it goes through patch_many anyway to keep one code path.
            replay = {}
            for ts, pid, fields in self._journal:
                if ts > new.xml_date and pid in new.tracks:
                    replay.setdefault(pid, {}).update(fields)
            replayed = len(replay)
            if replay:
                try:
                    new.patch_many(replay)
                except (KeyError, ValueError) as e:
                    log.warning("journal replay skipped: %s", e)
                    replayed = 0
            self._journal = [j for j in self._journal if j[0] > new.xml_date]

            for ts, op, plid, track_ids, name, extra in self._playlist_journal:
                if ts <= new.xml_date:
                    continue
                try:
                    self._apply_playlist_op(new, op, plid, track_ids, name, extra)
                except (KeyError, ValueError) as e:
                    log.warning("playlist journal replay skipped: %s", e)
            self._playlist_journal = [j for j in self._playlist_journal if j[0] > new.xml_date]

            self._lib = new
        self._reloading = False
        self.last_error = None
        log.info("swapped in reloaded library (%d journal entries replayed)", replayed)

    def patch(self, persistent_id, fields):
        return self.patch_many({persistent_id: fields})[persistent_id]

    def patch_many(self, patches):
        """One lock acquisition and at most one re-sort for the whole batch."""
        with self._lock:
            old = self._lib.patch_many(patches)
            now = time.time()
            for pid, fields in patches.items():
                self._journal.append((now, pid, dict(fields)))
        return old

    # -- playlist membership, journaled the same way as field patches ------

    def playlist_op(self, op, playlist_id, track_ids=(), name=None, parent_id=None, folder=False):
        """op is "create", "add" or "remove". Returns the operation's result."""
        extra = {"parent_id": parent_id, "folder": folder}
        with self._lock:
            result = self._apply_playlist_op(self._lib, op, playlist_id, track_ids, name, extra)
            self._playlist_journal.append((time.time(), op, playlist_id, list(track_ids), name, extra))
        return result

    @staticmethod
    def _apply_playlist_op(lib, op, playlist_id, track_ids, name, extra=None):
        extra = extra or {}
        if op == "create":
            return lib.playlist_create(playlist_id, name, extra.get("parent_id"), extra.get("folder", False))
        if op == "add":
            return lib.playlist_add(playlist_id, track_ids)
        if op == "remove":
            return lib.playlist_remove(playlist_id, track_ids)
        if op == "rename":
            return lib.playlist_rename(playlist_id, name)
        if op == "delete":
            return lib.playlist_delete(playlist_id)
        raise ValueError("unknown playlist op: %s" % op)

    def status(self):
        return {
            "reloading": self._reloading,
            "journalLength": len(self._journal),
            "playlistJournalLength": len(self._playlist_journal),
            "lastError": self.last_error,
        }
