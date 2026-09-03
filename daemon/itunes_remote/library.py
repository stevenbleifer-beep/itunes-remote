"""In-memory copy of the iTunes library, loaded from the XML plist.

Reads never touch iTunes. The XML is parsed once at startup and again, in a
background thread, whenever iTunes rewrites it. Writes made through the
daemon are patched into the in-memory copy immediately and journaled, so a
reload of a stale XML does not undo them.
"""

import logging
import os
import plistlib
import threading
import time
import unicodedata
from urllib.parse import unquote, urlsplit
from datetime import datetime, timezone

log = logging.getLogger("itunes_remote.library")


def fold(s):
    """Normalise for case-insensitive comparison. XML is NFC; be safe anyway."""
    return unicodedata.normalize("NFC", s or "").casefold()


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


# iTunes drops a leading article when sorting, so "The Beatles" files under B.
_ARTICLES = ("the ", "a ", "an ")


def sort_form(text, override=None):
    """iTunes' sort order for one field: its Sort override if the track has
    one, otherwise the text with a leading article removed."""
    value = fold(override or text or "")
    for article in _ARTICLES:
        if value.startswith(article) and len(value) > len(article):
            return value[len(article):]
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

    def _candidates(self, playlist=None):
        if playlist is None:
            return self.order
        p = self.playlists_by_id.get(playlist)
        if p is None:
            raise KeyError(playlist)
        return [self.tracks[pid] for pid in p["items"]]

    def _filter(self, tracks, q=None, genre=None, artist=None, album=None,
                composer=None, grouping=None):
        terms = [fold(x) for x in (q or "").split() if x]
        g = fold(genre) if genre is not None else None
        ar = fold(artist) if artist is not None else None
        al = fold(album) if album is not None else None
        co = fold(composer) if composer is not None else None
        gr = fold(grouping) if grouping is not None else None
        out = []
        for t in tracks:
            if g is not None and fold(t.genre) != g:
                continue
            if ar is not None and fold(t.artist) != ar:
                continue
            if al is not None and fold(t.album) != al:
                continue
            if co is not None and fold(t.composer) != co:
                continue
            if gr is not None and fold(t.grouping) != gr:
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
    )

    def query(self, q=None, genre=None, artist=None, album=None, composer=None,
              grouping=None, playlist=None, offset=0, limit=200, compact=False, recent=0):
        matched = self._filter(self._candidates(playlist), q, genre, artist, album, composer, grouping)
        if recent:
            matched = sorted(matched, key=lambda t: t.date_added or "", reverse=True)[:recent]
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
                 t.rating, t.play_count, t.composer, t.grouping, t.bpm, t.kind, t.date_added]
                for t in page
            ]
        else:
            out["tracks"] = [t.to_dict() for t in page]
        return out

    FACET_FIELDS = ("genre", "artist", "album", "composer", "grouping")

    def facet(self, field, q=None, genre=None, artist=None, album=None,
              composer=None, grouping=None, playlist=None):
        """Distinct values of `field` with counts, over the filtered set."""
        if field not in self.FACET_FIELDS:
            raise ValueError("not a browsable field: %s" % field)
        overrides = {"artist": "sort_artist", "album": "sort_album", "name": "sort_name"}
        override_attr = overrides.get(field)
        counts = {}
        display = {}
        order = {}
        for t in self._filter(self._candidates(playlist), q, genre, artist, album, composer, grouping):
            value = getattr(t, field) or ""
            key = fold(value)
            counts[key] = counts.get(key, 0) + 1
            if key not in display:
                display[key] = value
                override = getattr(t, override_attr) if override_attr else None
                order[key] = sort_form(value, override)
        return [
            {"name": display[k], "count": counts[k]}
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
        for t in self._filter(self._candidates(playlist), q, genre, artist, album, composer, grouping):
            display_artist = t.album_artist or t.artist
            key = (fold(display_artist), fold(t.album))
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
            order = sorted(groups, key=lambda k: groups[k]["dateAdded"] or "", reverse=True)[:recent]
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

    def playlist_create(self, persistent_id, name):
        entry = {
            "persistentId": persistent_id,
            "playlistId": None,
            "name": name,
            "smart": False,
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
        self._lib = None
        self._journal = []  # (timestamp, persistent_id, fields)
        self._playlist_journal = []  # (timestamp, op, playlist_id, track_ids, name)
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
            self._reload()
            pending_mtime = None

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

            for ts, op, plid, track_ids, name in self._playlist_journal:
                if ts <= new.xml_date:
                    continue
                try:
                    self._apply_playlist_op(new, op, plid, track_ids, name)
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

    def playlist_op(self, op, playlist_id, track_ids=(), name=None):
        """op is "create", "add" or "remove". Returns the operation's result."""
        with self._lock:
            result = self._apply_playlist_op(self._lib, op, playlist_id, track_ids, name)
            self._playlist_journal.append((time.time(), op, playlist_id, list(track_ids), name))
        return result

    @staticmethod
    def _apply_playlist_op(lib, op, playlist_id, track_ids, name):
        if op == "create":
            return lib.playlist_create(playlist_id, name)
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
