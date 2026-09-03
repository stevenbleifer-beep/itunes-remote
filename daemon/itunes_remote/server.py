"""HTTP API. Threaded so reads keep answering while a write is in flight."""

import hashlib
import gzip
import json
import logging
import os
import plistlib
import re
import subprocess
import tempfile
import threading
import time
from collections import OrderedDict
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlsplit

from . import artwork as artwork_mod
from .applescript import AppleScriptError, AppleScriptTimeout, ITunesNotRunning
from .library import Track, fold
from .syncplan import SyncPlans

log = logging.getLogger("itunes_remote.server")


def _epoch(iso):
    """The ISO timestamp Track keeps, as a POSIX time. 0 when absent."""
    if not iso:
        return 0.0
    try:
        return datetime.fromisoformat(iso).timestamp()
    except ValueError:
        return 0.0


class ApiError(Exception):
    def __init__(self, status, message):
        Exception.__init__(self, message)
        self.status = status
        self.message = message


class RawResponse(object):
    """A non-JSON body, e.g. image bytes."""

    def __init__(self, content_type, data, headers=None):
        self.content_type = content_type
        self.data = data
        self.headers = headers or {}


class FileResponse(object):
    """A file streamed from disk with HTTP range support, for local playback
    on the client. This is a read; nothing here ever writes to the library."""

    AUDIO_TYPES = {
        ".m4a": "audio/mp4", ".m4p": "audio/mp4", ".m4b": "audio/mp4", ".mp4": "audio/mp4",
        ".mp3": "audio/mpeg", ".wav": "audio/wav", ".aif": "audio/aiff", ".aiff": "audio/aiff",
    }

    def __init__(self, path):
        self.path = path
        ext = os.path.splitext(path)[1].lower()
        self.content_type = self.AUDIO_TYPES.get(ext, "application/octet-stream")


class Api(object):
    """Route table. Handlers take (params, query, body) and return a JSON-able
    object or a RawResponse. Everything that talks to iTunes goes through
    `itunes`, an AppleScript instance."""

    # The names the HTTP API accepts, mapped to Track's internal names. The
    # API is camelCase like the rest of the JSON; Track is snake_case.
    API_FIELDS = {
        "name": "name",
        "artist": "artist",
        "album": "album",
        "albumArtist": "album_artist",
        "genre": "genre",
        "composer": "composer",
        "grouping": "grouping",
        "bpm": "bpm",
        "year": "year",
        "trackNumber": "track_number",
        "discNumber": "disc_number",
        "compilation": "compilation",
        "enabled": "enabled",
        "rating": "rating",
    }
    NUMERIC_FIELDS = frozenset(("year", "track_number", "disc_number", "rating", "bpm"))
    BOOL_FIELDS = frozenset(("compilation", "enabled"))

    # Small enough that the Apple Events lock is released often, so the
    # client's once-a-second player poll still gets through a long edit.
    WRITE_CHUNK = 50

    def __init__(self, store, config, itunes=None, write_log=None):
        self.store = store
        self.config = config
        self.itunes = itunes
        self.write_log = write_log
        self.artwork_cache = OrderedDict()   # persistent id -> (mime, bytes) or None
        self.artwork_lock = threading.Lock()
        self.artwork_disk = artwork_mod.DiskCache(getattr(config, "artwork_cache_dir", ""))
        # When the last request was served, so the warmer can stay out of the
        # way while someone is actually using the app.
        self.last_request = 0.0
        self.warmer = None
        self.device_images = {}
        self._facet_cache = None
        self.plans = SyncPlans(getattr(config, "sync_plan_path",
                                       "~/Library/Application Support/iTunesRemote/sync.json"))
        # None = not tried, True = Accessibility works, False = give up.
        # Without the permission the System Events call hangs rather than
        # failing, so one bad result disables it: a 20 s block on every poll
        # would stall the Apple Events lock the player shares.
        self.alerts_readable = None
        pid = r"(?P<pid>[0-9A-Fa-f]{16})"
        self.routes = [
            ("GET", r"/api/library", self.get_library),
            ("GET", r"/api/tracks", self.get_tracks),
            ("GET", r"/api/tracks/" + pid, self.get_track),
            ("GET", r"/api/tracks/" + pid + r"/artwork", self.get_artwork),
            ("GET", r"/api/tracks/" + pid + r"/audio", self.get_audio),
            ("GET", r"/api/genres", self.get_genres),
            ("GET", r"/api/artists", self.get_artists),
            ("GET", r"/api/albums", self.get_albums),
            ("GET", r"/api/composers", self.get_composers),
            ("GET", r"/api/groupings", self.get_groupings),
            ("GET", r"/api/albumlist", self.get_album_list),
            ("GET", r"/api/playlists", self.get_playlists),
            ("GET", r"/api/playlists/" + pid + r"/tracks", self.get_playlist_tracks),
            ("GET", r"/api/itunes", self.get_itunes),
            ("GET", r"/api/itunes/alert", self.get_alert),
            ("POST", r"/api/itunes/alert/dismiss", self.post_alert_dismiss),
            ("POST", r"/api/itunes/launch", self.post_itunes_launch),
            ("GET", r"/api/player", self.get_player),
            ("POST", r"/api/player/play", self.post_play),
            ("POST", r"/api/player/(?P<cmd>pause|playpause|next|previous|stop)", self.post_player_cmd),
            ("POST", r"/api/player/volume", self.post_volume),
            ("POST", r"/api/player/shuffle", self.post_shuffle),
            ("POST", r"/api/player/repeat", self.post_repeat),
            ("POST", r"/api/player/position", self.post_position),
            ("GET", r"/api/sources", self.get_sources),
            ("GET", r"/api/sync", self.get_sync_plan),
            ("PUT", r"/api/sync", self.put_sync_plan),
            ("POST", r"/api/sync/toggle", self.post_sync_toggle),
            ("POST", r"/api/sync/rebuild", self.post_sync_rebuild),
            ("GET", r"/api/devices", self.get_devices),
            ("GET", r"/api/devices/(?P<name>[^/]+)", self.get_device),
            ("GET", r"/api/devices/(?P<name>[^/]+)/image", self.get_device_image),
            ("GET", r"/api/devices/(?P<name>[^/]+)/tracks", self.get_device_tracks),
            ("GET", r"/api/devices/(?P<name>[^/]+)/facets", self.get_device_facets),
            ("POST", r"/api/devices/(?P<name>[^/]+)/tracks", self.post_device_tracks),
            ("POST", r"/api/devices/(?P<name>[^/]+)/sync", self.post_source_sync),
            ("POST", r"/api/devices/(?P<name>[^/]+)/eject", self.post_source_eject),
            ("POST", r"/api/sources/(?P<name>[^/]+)/sync", self.post_source_sync),
            ("POST", r"/api/sources/(?P<name>[^/]+)/eject", self.post_source_eject),
            ("GET", r"/api/outputs", self.get_outputs),
            ("POST", r"/api/outputs", self.post_outputs),
            ("PATCH", r"/api/tracks", self.patch_tracks),
            ("POST", r"/api/playlists", self.post_playlist),
            ("PATCH", r"/api/playlists/" + pid, self.patch_playlist),
            ("DELETE", r"/api/playlists/" + pid, self.delete_playlist),
            ("POST", r"/api/playlists/" + pid + r"/tracks", self.post_playlist_tracks),
            ("DELETE", r"/api/playlists/" + pid + r"/tracks", self.delete_playlist_tracks),
        ]
        self.compiled = [(m, re.compile("^" + p + "$"), h) for m, p, h in self.routes]

    def dispatch(self, method, path, query, body):
        # The warmer stays quiet for a while after any request, so it never
        # competes with someone actually using the app.
        self.last_request = time.time()
        matched_path = False
        for m, rx, handler in self.compiled:
            match = rx.match(path)
            if match is None:
                continue
            matched_path = True
            if m != method:
                continue
            return handler(match.groupdict(), query, body)
        if matched_path:
            raise ApiError(405, "method not allowed")
        if path.startswith("/api/"):
            raise ApiError(501, "not implemented in this milestone: %s %s" % (method, path))
        raise ApiError(404, "no such route")

    # -- helpers --------------------------------------------------------

    @staticmethod
    def _one(query, key, default=None):
        values = query.get(key)
        return values[0] if values else default

    @staticmethod
    def _int(query, key, default, lo, hi):
        raw = Api._one(query, key)
        if raw is None or raw == "":
            return default
        try:
            v = int(raw)
        except ValueError:
            raise ApiError(400, "%s must be an integer" % key)
        return max(lo, min(hi, v))

    def _filters(self, query):
        return {
            "q": self._one(query, "q"),
            "genre": self._one(query, "genre"),
            "artist": self._one(query, "artist"),
            "album": self._one(query, "album"),
            "composer": self._one(query, "composer"),
            "grouping": self._one(query, "grouping"),
            "playlist": self._one(query, "playlist"),
        }

    def _script(self, name, *args, **kw):
        """Runs an AppleScript and maps its failures to HTTP errors."""
        if self.itunes is None:
            raise ApiError(501, "AppleScript is not configured")
        try:
            return self.itunes.run(name, *args, **kw)
        except ITunesNotRunning as e:
            raise ApiError(503, str(e))
        except AppleScriptTimeout as e:
            raise ApiError(504, str(e))
        except AppleScriptError as e:
            raise ApiError(502, str(e))

    @staticmethod
    def _num(s, default=0):
        try:
            if "." in s or "E" in s or "e" in s:
                return float(s)
            return int(s)
        except (ValueError, TypeError):
            return default

    @staticmethod
    def _bool(s):
        return s.strip().lower() == "true"

    # -- library reads --------------------------------------------------

    ITUNES_INFO_PLIST = "/Applications/iTunes.app/Contents/Info.plist"
    _itunes_version = None

    @classmethod
    def itunes_version(cls):
        """iTunes' marketing version (12.9.5), not the XML's build string (12.9.5.5)."""
        if cls._itunes_version is None:
            try:
                with open(cls.ITUNES_INFO_PLIST, "rb") as f:
                    cls._itunes_version = plistlib.load(f).get("CFBundleShortVersionString", "")
            except (OSError, ValueError):
                cls._itunes_version = ""
        return cls._itunes_version

    def get_library(self, params, query, body):
        info = self.store.lib.info()
        info.update(self.store.status())
        info["itunesVersion"] = self.itunes_version() or info.get("applicationVersion", "")
        return info

    def _page(self, query, f):
        compact = self._one(query, "compact", "0") not in ("0", "", "false")
        offset = self._int(query, "offset", 0, 0, 10 ** 9)
        limit = self._int(query, "limit", 200, 1, 200000 if compact else 5000)
        recent = self._int(query, "recent", 0, 0, 20000)
        try:
            return self.store.lib.query(offset=offset, limit=limit, compact=compact, recent=recent, **f)
        except KeyError:
            raise ApiError(404, "no such playlist")

    def get_tracks(self, params, query, body):
        return self._page(query, self._filters(query))

    def get_track(self, params, query, body):
        t = self.store.lib.tracks.get(params["pid"].upper())
        if t is None:
            raise ApiError(404, "no such track")
        return t.to_dict()

    def _facet(self, field, query):
        f = self._filters(query)
        # A pane does not narrow itself: browsing Genres shows every genre for
        # the other filters, exactly as the iTunes column browser behaved.
        f.pop(field, None)
        f["recent"] = self._int(query, "recent", 0, 0, 20000)
        try:
            return {field + "s": self.store.lib.facet(field, **f)}
        except KeyError:
            raise ApiError(404, "no such playlist")
        except ValueError as e:
            raise ApiError(400, str(e))

    def get_genres(self, params, query, body):
        return self._facet("genre", query)

    def get_artists(self, params, query, body):
        return self._facet("artist", query)

    def get_albums(self, params, query, body):
        return self._facet("album", query)

    def get_composers(self, params, query, body):
        return self._facet("composer", query)

    def get_groupings(self, params, query, body):
        return self._facet("grouping", query)

    def get_album_list(self, params, query, body):
        f = self._filters(query)
        recent = self._int(query, "recent", 0, 0, 20000)
        try:
            return {"albums": self.store.lib.albums(recent=recent, **f)}
        except KeyError:
            raise ApiError(404, "no such playlist")

    def get_playlists(self, params, query, body):
        return {"playlists": self.store.lib.playlist_summaries()}

    def get_playlist_tracks(self, params, query, body):
        f = self._filters(query)
        f["playlist"] = params["pid"].upper()
        return self._page(query, f)

    # -- artwork --------------------------------------------------------

    ARTWORK_CACHE_SIZE = 300

    def _artwork(self, pid, allow_itunes=True):
        with self.artwork_lock:
            if pid in self.artwork_cache:
                self.artwork_cache.move_to_end(pid)
                return self.artwork_cache[pid]
        t = self.store.lib.tracks.get(pid)
        if t is None:
            raise ApiError(404, "no such track")
        # A cover cached before the track was last modified is stale.
        cached = self.artwork_disk.get(pid, not_before=_epoch(t.date_modified))
        if cached is not None:
            result = None if cached is artwork_mod.MISS else cached
            self._remember(pid, result)
            return result
        result = None
        if t.location:
            result = artwork_mod.read_embedded(t.location)
        embedded = result is not None
        asked_itunes = False
        if result is None and allow_itunes and self.itunes is not None and self.itunes.itunes_running():
            asked_itunes = True
            # Ask iTunes: covers WAV/AIFF and anything with art only in the library.
            fd, tmp = tempfile.mkstemp(prefix="itr-art-", suffix=".bin")
            os.close(fd)
            try:
                out = self._script("artwork_export", pid, tmp, timeout=30)
                if out.startswith("ok"):
                    with open(tmp, "rb") as f:
                        data = f.read()
                    mime = artwork_mod.sniff(data)
                    if mime:
                        result = (mime, data)
            except ApiError as e:
                log.info("artwork export for %s failed: %s", pid, e.message)
            finally:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
        # Only exported covers are worth keeping on disk; embedded art is a
        # cheap read from the file itself. A miss is worth recording too, so
        # the next request does not pay for the export again — but only once
        # iTunes has actually answered. Recording a miss while iTunes was down
        # would stick until the track changed.
        if not embedded and asked_itunes:
            self.artwork_disk.put(pid, result)
        self._remember(pid, result)
        return result

    # -- background warmer ----------------------------------------------

    def start_artwork_warmer(self):
        """Exports the covers Cover Flow and Grid will ask for, one at a time,
        only while nothing else is using the daemon.

        Cover Flow's problem was never one cover; it was thousands queued
        behind the single Apple Events lock. With the covers already on disk
        the lock is never taken during a scrub. This fills that disk cache
        during the idle time a dedicated iTunes machine has plenty of."""
        if not getattr(self.config, "artwork_warm", False):
            return
        self.warmer = threading.Thread(target=self._warm_loop, name="artwork-warmer", daemon=True)
        self.warmer.start()

    def _warm_loop(self):
        idle = max(5.0, float(getattr(self.config, "artwork_warm_idle", 20)))
        # Let the library settle and the first client finish loading.
        time.sleep(idle)
        done = 0
        while True:
            try:
                queue = self._warm_queue()
            except Exception as e:
                log.warning("artwork warmer could not build its queue: %s", e)
                return
            if not queue:
                log.info("artwork warmer: nothing left to fetch (%d covers on disk)",
                         self.artwork_disk.count())
                return
            log.info("artwork warmer: %d covers to fetch", len(queue))
            for pid in queue:
                # Anyone using the app wins; wait for quiet before each cover.
                while time.time() - self.last_request < idle:
                    time.sleep(2.0)
                if self.itunes is None or not self.itunes.itunes_running():
                    time.sleep(idle)
                    continue
                try:
                    self._artwork(pid)
                except ApiError:
                    pass
                except Exception as e:
                    log.info("artwork warmer stopped on %s: %s", pid, e)
                    return
                done += 1
                if done % 200 == 0:
                    log.info("artwork warmer: %d fetched", done)
                # Never hold the lock back to back.
                time.sleep(0.4)
            # A pass can leave stragglers if the library reloaded underneath
            # it; go round again, and the empty queue above ends the thread.

    def _warm_queue(self):
        """One cover track per album, skipping anything already on disk or
        readable straight out of the file."""
        lib = self.store.lib
        out = []
        for album in lib.albums():
            pid = album.get("coverTrackId")
            if not pid or album.get("hasArtwork"):
                # hasArtwork means iTunes says the file carries the picture,
                # which read_embedded gets without touching iTunes.
                continue
            t = lib.tracks.get(pid)
            if t is None:
                continue
            if self.artwork_disk.get(pid, not_before=_epoch(t.date_modified)) is not None:
                continue
            out.append(pid)
        return out

    def _remember(self, pid, result):
        with self.artwork_lock:
            self.artwork_cache[pid] = result
            self.artwork_cache.move_to_end(pid)
            while len(self.artwork_cache) > self.ARTWORK_CACHE_SIZE:
                self.artwork_cache.popitem(last=False)

    def get_artwork(self, params, query, body):
        pid = params["pid"].upper()
        result = self._artwork(pid)
        if result is None:
            raise ApiError(404, "no artwork")
        mime, data = result
        etag = '"%s"' % hashlib.sha1(data).hexdigest()[:16]
        return RawResponse(mime, data, {"ETag": etag, "Cache-Control": "max-age=86400"})

    def get_audio(self, params, query, body):
        """The track's file, for the client to play on its own speakers."""
        t = self.store.lib.tracks.get(params["pid"].upper())
        if t is None:
            raise ApiError(404, "no such track")
        if not t.location or not os.path.isfile(t.location):
            raise ApiError(404, "the file for this track is not on disk")
        return FileResponse(t.location)

    # -- iTunes process -------------------------------------------------

    def get_itunes(self, params, query, body):
        if self.itunes is None:
            return {"running": False, "ipodMounted": False, "configured": False}
        return {
            "running": self.itunes.itunes_running(),
            "ipodMounted": self.itunes.ipod_mounted(),
            "configured": True,
        }

    def get_alert(self, params, query, body):
        """Any modal dialog iTunes is showing. Read-only.

        iTunes raises alerts that no AppleScript call ever returns (a failed
        AirPlay pick, sync warnings), and on a headless machine nobody sees
        them. This surfaces them; dismissing is a separate, explicit call.
        """
        if self._one(query, "recheck") not in (None, "", "0"):
            self.alerts_readable = None
        if self.itunes is None or not self.itunes.itunes_running():
            return {"alert": None, "readable": bool(self.alerts_readable)}
        if self.alerts_readable is False:
            return {"alert": None, "readable": False}
        try:
            out = self._script("alert_read", timeout=6, serialize=False)
        except ApiError as e:
            # A timeout here means Accessibility was never granted; stop asking.
            self.alerts_readable = False
            log.info("alerts unreadable, disabling the check: %s", e.message)
            return {"alert": None, "readable": False}
        self.alerts_readable = True
        if not out.strip():
            return {"alert": None, "readable": True}
        parts = self.itunes.fields(out)
        return {"alert": {"message": parts[0], "buttons": [p for p in parts[1:] if p]}, "readable": True}

    def post_alert_dismiss(self, params, query, body):
        button = (body or {}).get("button")
        if not isinstance(button, str) or not button.strip():
            raise ApiError(400, "body needs the button name to click")
        if self.alerts_readable is False:
            raise ApiError(409, "iTunes dialogs are not readable; grant Accessibility to Python")
        # Also outside the lock: the point of dismissing a dialog is usually
        # to unblock whatever is holding it.
        out = self._script("alert_click", button, timeout=20, serialize=False)
        if self.write_log:
            self.write_log.record("alert-dismiss", None, None, {"button": button}, "ok", out)
        return {"result": out}

    def post_itunes_launch(self, params, query, body):
        if self.itunes is None:
            raise ApiError(501, "AppleScript is not configured")
        try:
            self.itunes.launch_itunes()
        except AppleScriptError as e:
            raise ApiError(409, str(e))
        return {"launched": True}

    # -- player ---------------------------------------------------------

    def get_player(self, params, query, body):
        f = self.itunes.fields(self._script("player_state", timeout=15))
        if len(f) < 11:
            raise ApiError(502, "unexpected player state: %r" % f)
        state = {
            "state": f[0],
            "volume": self._num(f[1]),
            "position": self._num(f[2]),
            "track": None,
            "playlist": None,
        }
        if f[3]:
            state["track"] = {
                "persistentId": f[3],
                "databaseId": self._num(f[4]),
                "name": f[5],
                "artist": f[6],
                "album": f[7],
                "duration": self._num(f[8]),
            }
        if f[10]:
            state["playlist"] = {"name": f[9], "persistentId": f[10]}
        state["shuffle"] = len(f) > 11 and self._bool(f[11])
        state["repeat"] = f[12] if len(f) > 12 else "off"
        return state

    def post_shuffle(self, params, query, body):
        enabled = bool((body or {}).get("enabled"))
        out = self._script("player_set", "shuffle", "true" if enabled else "false", timeout=15)
        return {"shuffle": self._bool(out)}

    def post_repeat(self, params, query, body):
        mode = (body or {}).get("mode")
        if mode not in ("off", "one", "all"):
            raise ApiError(400, "mode must be off, one or all")
        out = self._script("player_set", "repeat", mode, timeout=15)
        return {"repeat": out.strip()}

    def post_play(self, params, query, body):
        body = body or {}
        track = body.get("track")
        playlist = body.get("playlist")
        if track:
            if not re.match(r"^[0-9A-Fa-f]{16}$", track):
                raise ApiError(400, "track must be a persistent ID")
            if track.upper() not in self.store.lib.tracks:
                raise ApiError(404, "no such track")
            args = [track.upper()]
            if playlist:
                if not re.match(r"^[0-9A-Fa-f]{16}$", playlist):
                    raise ApiError(400, "playlist must be a persistent ID")
                args.append(playlist.upper())
            played = self._script("play_track", *args, timeout=30)
            return {"playing": played}
        self._script("player_cmd", "play", timeout=15)
        return {"ok": True}

    def post_player_cmd(self, params, query, body):
        self._script("player_cmd", params["cmd"], timeout=15)
        return {"ok": True}

    def post_volume(self, params, query, body):
        try:
            v = int((body or {})["volume"])
        except (KeyError, ValueError, TypeError):
            raise ApiError(400, "body needs an integer volume 0-100")
        v = max(0, min(100, v))
        out = self._script("set_volume", v, timeout=15)
        return {"volume": self._num(out, v)}

    def post_position(self, params, query, body):
        try:
            p = float((body or {})["position"])
        except (KeyError, ValueError, TypeError):
            raise ApiError(400, "body needs a numeric position in seconds")
        out = self._script("set_position", max(0.0, p), timeout=15)
        return {"position": self._num(out, p)}

    # -- sources (read-only; sync is gated on the section 7 probe) --------

    def get_sources(self, params, query, body):
        recs = self.itunes.records(self._script("sources_list", timeout=20))
        out = []
        for r in recs:
            if not r or not r[0]:
                continue
            free = self._num(r[2], -1) if len(r) > 2 else -1
            cap = self._num(r[3], -1) if len(r) > 3 else -1
            out.append({
                "name": r[0],
                "kind": r[1] if len(r) > 1 else "unknown",
                "freeSpace": None if free < 0 else int(free),
                "capacity": None if cap < 0 else int(cap),
            })
        return {"sources": out}

    # -- the app's own sync plan ----------------------------------------

    # Reading the iPod costs iTunes a couple of seconds under the Apple Events
    # lock. Ticking a row on the Music pane asked for it every time, so a run
    # of clicks queued up behind device reads; keep the answer briefly.
    POD_CACHE_SECONDS = 15

    def _connected_pod(self):
        """The iPod iTunes currently has open, with its serial. Serial is the
        plan key: Steven has five iPods and two are the same model, so names
        would collide."""
        cached = getattr(self, "_pod_cache", None)
        if cached and time.time() - cached[0] < self.POD_CACHE_SECONDS:
            return cached[1]
        pod = self._read_connected_pod()
        self._pod_cache = (time.time(), pod)
        return pod

    def _read_connected_pod(self):
        try:
            devices = self.get_devices({}, None, None)["devices"]
        except ApiError:
            return None
        pod = next((d for d in devices if d["kind"] == "iPod" and d.get("itunesSource")), None)
        if pod is None:
            return None
        detail = self.get_device({"name": quote(pod["name"], safe="")}, None, None)
        return {
            "name": detail.get("name"),
            "serial": detail.get("deviceSerialNumber") or detail.get("serialNumber"),
            "detail": detail,
        }

    def _plan_track_ids(self, plan):
        """Every library track the plan covers, matched the way the rebuild
        script matches: case-insensitive equality on the field itself."""
        lib = self.store.lib
        sel = plan.selections
        ids = set()
        if sel["playlist"]:
            wanted = {fold(n) for n in sel["playlist"]}
            for p in lib.playlists_by_id.values():
                if fold(p.get("name")) in wanted:
                    ids.update(p["items"])
        artists = {fold(a) for a in sel["artist"]}
        album_artists = {fold(a) for a in sel["albumartist"]}
        genres = {fold(g) for g in sel["genre"]}
        albums = {(fold(a), fold(b)) for a, b in sel["album"]}
        if artists or album_artists or genres or albums:
            for t in lib.tracks.values():
                if artists and fold(t.artist) in artists:
                    ids.add(t.persistent_id)
                elif album_artists and fold(t.album_artist) in album_artists:
                    ids.add(t.persistent_id)
                elif genres and fold(t.genre) in genres:
                    ids.add(t.persistent_id)
                elif albums and ((fold(t.artist), fold(t.album)) in albums
                                 or ("", fold(t.album)) in albums):
                    ids.add(t.persistent_id)
        return ids

    def _resolve_plan(self, body, query, create=True):
        """Finds the plan a request is about: an explicit device key, else the
        iPod that is plugged in."""
        key = (body or {}).get("device") or self._one(query or {}, "device")
        label = (body or {}).get("label")
        if not key:
            pod = self._connected_pod()
            if pod is None or not pod["serial"]:
                raise ApiError(404, "no iPod is connected; pass a device serial")
            key, label = pod["serial"], label or pod["name"]
        try:
            plan = self.plans.plan_for(key, label=label, create=create)
        except ValueError as e:
            raise ApiError(400, str(e))
        if plan is None:
            raise ApiError(404, "no plan for device %r" % key)
        return plan

    def _plan_status(self, plan):
        """Where a plan stands against iTunes. Reads only."""
        lib = self.store.lib
        existing = next((p for p in lib.playlist_summaries()
                         if p["name"] == plan.playlist_name), None)
        on_device = None
        pod = self._connected_pod()
        if pod is not None:
            if pod["serial"] and pod["serial"] != plan.key:
                on_device = None          # a different iPod is plugged in
            else:
                on_device = any(p["name"] == plan.playlist_name
                                for p in pod["detail"].get("playlists", []))
        return {
            "playlistExists": existing is not None,
            "playlistId": existing["persistentId"] if existing else None,
            "playlistTrackCount": existing["count"] if existing else 0,
            # Distinct library tracks the plan covers — the number iTunes'
            # own Music pane puts in its heading.
            "trackCount": len(self._plan_track_ids(plan)),
            # None means it could not be checked, not that the answer is no.
            "playlistOnDevice": on_device,
            "connectedSerial": pod["serial"] if pod else None,
            "isConnected": bool(pod and pod["serial"] == plan.key),
            "ready": bool(existing) and on_device is True,
            "setupHint": (
                "In iTunes on the MacBook Pro, on this iPod's Music pane, leave your own "
                "playlists ticked and tick %r as well, then untick the individual artists, "
                "albums and genres. Until then this plan changes nothing."
                % plan.playlist_name
            ),
        }

    def get_sync_plan(self, params, query, body):
        """Every device's plan, plus the one for whatever is plugged in.

        Each pane's ticks stand on their own, the way iTunes' Music pane works:
        a plan is the union of the playlists, artists, album artists, genres
        and albums it names. Ticking an artist means that artist, not a
        shorthand for its albums."""
        pod = self._connected_pod()
        out = self.plans.to_dict()
        out["connected"] = {"name": pod["name"], "serial": pod["serial"]} if pod else None
        wanted = self._one(query or {}, "device") or (pod["serial"] if pod else None)
        if wanted:
            plan = self.plans.plan_for(wanted, label=(pod["name"] if pod else None))
            out["plan"] = plan.to_dict()
            out["status"] = self._plan_status(plan)
        return out

    def put_sync_plan(self, params, query, body):
        """Replaces a device's selection. Recorded only — nothing reaches
        iTunes until /api/sync/rebuild is called for that device."""
        plan = self._resolve_plan(body, query)
        body = body or {}
        try:
            plan.replace(playlist_name=body.get("playlistName"),
                         selections=body.get("selections"),
                         label=body.get("label"))
        except ValueError as e:
            raise ApiError(400, str(e))
        if self.write_log:
            self.write_log.record("sync-plan", plan.playlist_name, None, None, "ok",
                                  json.dumps(plan.to_dict()["counts"]))
        return {"plan": plan.to_dict(), "status": self._plan_status(plan)}

    def post_sync_toggle(self, params, query, body):
        """Adds or removes one item for a device. Recorded only; no rebuild."""
        plan = self._resolve_plan(body, query)
        body = body or {}
        kind, value = body.get("kind"), body.get("value")
        if kind is None or value is None:
            raise ApiError(400, "body needs kind and value")
        on = bool(body.get("on", True))
        try:
            plan.toggle(kind, value, on)
        except ValueError as e:
            raise ApiError(400, str(e))
        return {"plan": plan.to_dict(), "status": self._plan_status(plan)}

    def post_sync_rebuild(self, params, query, body):
        """Writes a device's plan to its playlist in iTunes. The only call here
        that changes anything, and it is never automatic."""
        plan = self._resolve_plan(body, query, create=False)
        if plan.is_empty():
            raise ApiError(400, "the plan for %r is empty; nothing would be synced"
                                % plan.label)
        # Feed the spec in chunks. A single run with a few thousand compound
        # `whose` filters is killed part way through and leaves the playlist
        # half built, with osascript reporting nothing at all.
        lines = plan.spec_lines()
        total = 0
        done = 0
        for start in range(0, len(lines), self.REBUILD_CHUNK):
            chunk = lines[start:start + self.REBUILD_CHUNK]
            fd, spec = tempfile.mkstemp(prefix="itr-sync-", suffix=".tsv")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write("\n".join(chunk) + "\n")
            try:
                mode = "replace" if start == 0 else "append"
                out = self._script("sync_rebuild", plan.playlist_name, spec, mode, timeout=900)
                total = int(self._num(out.strip(), 0))
                done += len(chunk)
                log.info("sync rebuild %s: %d/%d selections, %d tracks so far",
                         plan.playlist_name, done, len(lines), total)
            except ApiError as e:
                raise ApiError(e.status,
                               "rebuild stopped after %d of %d selections (%d tracks in the "
                               "playlist): %s" % (done, len(lines), total, e.message))
            finally:
                try:
                    os.unlink(spec)
                except OSError:
                    pass
        if self.write_log:
            self.write_log.record("sync-rebuild", plan.playlist_name, None, None, "ok",
                                  "%d tracks" % total)
        return {"plan": plan.to_dict(), "status": self._plan_status(plan),
                "rebuilt": {"playlist": plan.playlist_name, "trackCount": total}}

    # -- devices --------------------------------------------------------

    # What iTunes calls a source that is a physical thing you can sync.
    DEVICE_KINDS = ("iPod", "device", "audio CD", "MP3 CD")

    # USB product names that are Apple devices iTunes might manage. Used only
    # to notice a device iTunes has not surfaced as a source, so the page can
    # say so instead of showing nothing.
    APPLE_DEVICE_NAMES = ("ipod", "iphone", "ipad")

    # The device page asks on every open; the USB tree rarely changes and
    # system_profiler costs ~0.3 s.
    USB_CACHE_SECONDS = 10.0

    def _usb_devices(self):
        """Apple devices on the USB bus, by serial number, from system_profiler.
        Gives the serial, the link speed and the mounted volume, none of which
        iTunes' AppleScript dictionary exposes."""
        now = time.time()
        cached = getattr(self, "_usb_cache", None)
        if cached and now - cached[0] < self.USB_CACHE_SECONDS:
            return cached[1]
        found = []
        try:
            r = subprocess.run(["system_profiler", "-xml", "SPUSBDataType"],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20)
            tree = plistlib.loads(r.stdout)
        except Exception as e:                       # a probe, never fatal
            log.warning("system_profiler failed: %s", e)
            tree = []

        def walk(items):
            for item in items or []:
                name = (item.get("_name") or "")
                if any(k in name.lower() for k in self.APPLE_DEVICE_NAMES):
                    found.append(self._usb_record(name, item))
                walk(item.get("_items"))

        for section in tree:
            walk(section.get("_items"))
        self._usb_cache = (now, found)
        return found

    @staticmethod
    def _usb_record(name, item):
        speeds = {"low_speed": "USB 1.5 Mb/s", "full_speed": "USB 12 Mb/s",
                  "high_speed": "USB 480 Mb/s", "super_speed": "USB 5 Gb/s"}
        rec = {
            "productName": name,
            "serialNumber": item.get("serial_num"),
            "connection": speeds.get(item.get("device_speed"), item.get("device_speed")),
            "manufacturer": item.get("manufacturer"),
            "mountPoint": None,
            "fileSystem": None,
            "volumeName": None,
            "capacity": None,
            "freeSpace": None,
        }
        for media in item.get("Media") or []:
            for vol in media.get("volumes") or []:
                if not vol.get("mount_point"):
                    continue
                rec["mountPoint"] = vol.get("mount_point")
                rec["fileSystem"] = vol.get("file_system")
                rec["volumeName"] = vol.get("_name")
                rec["capacity"] = vol.get("size_in_bytes")
                rec["freeSpace"] = vol.get("free_space_in_bytes")
        return rec

    def get_devices(self, params, query, body):
        """Every device iTunes can see, plus any Apple device on the USB bus
        that iTunes has not picked up, so the page can explain the difference
        rather than showing an empty list."""
        try:
            sources = self.get_sources(params, None, None)["sources"]
        except ApiError as e:
            if e.status != 503:
                raise
            sources = []                             # iTunes down; USB still tells us something
        usb = self._usb_devices()
        claimed = set()
        out = []
        for s in sources:
            if s["kind"] not in self.DEVICE_KINDS:
                continue
            dev = dict(s, itunesSource=True, syncable=s["kind"] == "iPod")
            match = self._match_usb(s["name"], usb, claimed)
            if match:
                dev.update({k: v for k, v in match.items()
                            if v is not None and k not in ("capacity", "freeSpace")})
            out.append(dev)
        for i, u in enumerate(usb):
            if i in claimed:
                continue
            out.append(dict(u,
                            name=u.get("volumeName") or u["productName"],
                            kind=u["productName"],
                            itunesSource=False,
                            syncable=False))
        return {"devices": out}

    @staticmethod
    def _match_usb(source_name, usb, claimed):
        """Pair an iTunes source with a USB device. The names rarely agree —
        iTunes shows the user's device name, USB shows the model — so match on
        the mounted volume name first and fall back to the only unclaimed
        Apple device."""
        folded = source_name.strip().casefold()
        for i, u in enumerate(usb):
            if i in claimed:
                continue
            if (u.get("volumeName") or "").strip().casefold() == folded:
                claimed.add(i)
                return u
        free = [i for i in range(len(usb)) if i not in claimed]
        if len(free) == 1:
            claimed.add(free[0])
            return usb[free[0]]
        return None

    # iTunes' own names for the media a device holds, in the order its
    # capacity bar drew them.
    CATEGORY_ORDER = ("Music", "Movies", "TV Shows", "Podcasts", "Books",
                      "Audiobooks", "Purchased Music", "Tones")

    # iTunes records every iPod it has seen here, keyed by the same id the USB
    # bus reports. It is the only place the device's printed serial number and
    # its firmware version can be read; AppleScript exposes neither.
    IPOD_PREFS = "~/Library/Preferences/com.apple.iPod.plist"

    def _ipod_prefs(self, usb_id):
        if not usb_id:
            return {}
        try:
            with open(os.path.expanduser(self.IPOD_PREFS), "rb") as f:
                prefs = plistlib.load(f)
        except (OSError, ValueError) as e:
            log.info("could not read %s: %s", self.IPOD_PREFS, e)
            return {}
        rec = (prefs.get("Devices") or {}).get(usb_id)
        if not isinstance(rec, dict):
            return {}
        connected = rec.get("Connected")
        return {
            "deviceSerialNumber": rec.get("Serial Number"),
            "softwareVersion": rec.get("Firmware Version String"),
            "familyId": rec.get("Family ID"),
            "deviceClass": rec.get("Device Class"),
            "productType": rec.get("Product Type"),
            "useCount": rec.get("Use Count"),
            "lastConnected": connected.isoformat() if hasattr(connected, "isoformat") else None,
        }

    # iTunes says "Macintosh" or "Windows", not the filesystem's own name.
    FORMAT_NAMES = (
        ("hfs", "Macintosh"), ("apfs", "Macintosh"),
        ("fat", "Windows"), ("ntfs", "Windows"), ("exfat", "Windows"),
    )

    @staticmethod
    def _format_name(filesystem):
        low = (filesystem or "").lower()
        for needle, name in Api.FORMAT_NAMES:
            if needle in low:
                return name
        return filesystem or None

    # iTunes.app carries one image per device family, named by the Family ID
    # that its own preferences record. Serving it from here beats bundling
    # 15 MB of artwork in the client, and it stays right for any device.
    ITUNES_RESOURCES = "/Applications/iTunes.app/Contents/Resources"
    IMAGE_COLOURS = ("Black", "Silver", "SpaceGray", "DarkGray", "Blue", "Green", "Pink", "Red")

    def _device_image_path(self, family_id):
        if not family_id:
            return None
        for colour in self.IMAGE_COLOURS:
            path = os.path.join(self.ITUNES_RESOURCES, "iPod%s-%s.icns" % (family_id, colour))
            if os.path.exists(path):
                return path
        path = os.path.join(self.ITUNES_RESOURCES, "iPod%s.icns" % family_id)
        return path if os.path.exists(path) else None

    def get_device_image(self, params, query, body):
        """The device's own picture, as iTunes draws it, converted to PNG."""
        name = unquote(params["name"])
        detail = self.get_device({"name": params["name"]}, None, None)
        path = self._device_image_path(detail.get("familyId"))
        if path is None:
            raise ApiError(404, "no image for %r" % name)
        size = self._int(query, "size", 256, 32, 512)
        key = (path, size)
        with self.artwork_lock:
            cached = self.device_images.get(key)
        if cached is None:
            fd, tmp = tempfile.mkstemp(prefix="itr-dev-", suffix=".png")
            os.close(fd)
            try:
                r = subprocess.run(["sips", "-s", "format", "png", "-Z", str(size), path, "--out", tmp],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
                if r.returncode != 0:
                    raise ApiError(502, "could not convert %s" % os.path.basename(path))
                with open(tmp, "rb") as f:
                    cached = f.read()
            except subprocess.SubprocessError as e:
                raise ApiError(502, "could not convert the device image: %s" % e)
            finally:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
            with self.artwork_lock:
                self.device_images[key] = cached
        etag = '"%s"' % hashlib.sha1(cached).hexdigest()[:16]
        return RawResponse("image/png", cached, {"ETag": etag, "Cache-Control": "max-age=86400"})

    # The device page lists what is on the iPod. A whole 23,000-track device
    # list is neither useful nor quick to draw, so it is paged from the top.
    DEVICE_TRACK_LIMIT = 2000

    def get_device_tracks(self, params, query, body):
        """The tracks on a device, from one of its playlists."""
        name = unquote(params["name"])
        playlist = self._one(query, "playlist") or "Music"
        limit = self._int(query, "limit", 500, 1, self.DEVICE_TRACK_LIMIT)
        out = self._script("device_tracks", name, playlist, limit, timeout=90)
        if not out:
            return {"device": name, "playlist": playlist, "tracks": []}
        columns = out.split("\x1e")
        if len(columns) < 4:
            raise ApiError(502, "unexpected reply listing %r" % playlist)
        names, artists, albums, times = [c.split("\x1f") for c in columns[:4]]
        rows = []
        for i, n in enumerate(names):
            def at(seq):
                return seq[i] if i < len(seq) else ""
            rows.append({
                "name": n,
                "artist": at(artists),
                "album": at(albums),
                # AppleScript's `duration` is seconds; the client works in ms.
                "totalTime": int(self._num(at(times), 0) * 1000),
            })
        return {"device": name, "playlist": playlist, "tracks": rows,
                "truncated": len(rows) >= limit}

    # How many selections go into one osascript run. Small enough that a run
    # finishes well inside its timeout even when every one is a compound
    # album filter over a 95,000-track library.
    REBUILD_CHUNK = 150

    # Copying onto a device is one AppleScript call per track, and each one
    # can fail on its own, so keep the batches small enough that the Apple
    # Events lock is released often.
    DEVICE_ADD_CHUNK = 25

    def post_device_tracks(self, params, query, body):
        """Copies library tracks onto a device — what a drag and drop does.

        iTunes allows this only when the device is set to manual management;
        otherwise every copy fails with -54. That is reported as the setting
        it is, not as a mystery error."""
        name = self._ipod_name(params)
        ids = (body or {}).get("tracks")
        if not isinstance(ids, list) or not ids:
            raise ApiError(400, "tracks must be a non-empty list of persistent IDs")
        ids = [str(i).upper() for i in ids]
        for pid in ids:
            if pid not in self.store.lib.tracks:
                raise ApiError(404, "no such track: %s" % pid)
        added, failed = [], []
        for start in range(0, len(ids), self.DEVICE_ADD_CHUNK):
            chunk = ids[start:start + self.DEVICE_ADD_CHUNK]
            recs = self.itunes.records(self._script("device_add", name, *chunk, timeout=180))
            for r in recs:
                if len(r) > 1 and r[1] == "ok":
                    added.append(r[0])
                else:
                    # Keep the AppleScript number in the text: -54 is how
                    # iTunes says "this device is not manually managed", and
                    # the message alone does not say that.
                    code = r[1] if len(r) > 1 else "failed"
                    message = r[2] if len(r) > 2 else ""
                    failed.append({"persistentId": r[0],
                                   "error": ("%s: %s" % (code, message)).strip(": ")})
        if self.write_log:
            self.write_log.record("device-add", name, None, None,
                                  "ok" if not failed else "partial",
                                  "%d added, %d failed" % (len(added), len(failed)))
        out = {"device": name, "added": added, "failed": failed}
        if failed and not added and any("-54" in (f["error"] or "")
                                        or "permission" in (f["error"] or "").lower()
                                        for f in failed):
            out["reason"] = (
                "iTunes refused every copy. It only accepts tracks dragged onto a device "
                "when that device is set to \u201cManually manage music and videos\u201d; "
                "%s is set to sync selected playlists instead. Turn that on in iTunes on "
                "the MacBook Pro, or drop the tracks on a playlist that %s syncs." % (name, name)
            )
        return out

    def get_device_facets(self, params, query, body):
        """Which artists, albums and genres reached the device.

        iTunes' Music pane ticks the ones its sync selection names. That
        selection lives in the library database and is readable by nothing —
        not AppleScript, not the preference files, not the accessibility tree.
        What is on the device is readable, so the pane marks that instead, and
        says so. Cached until the device's track count changes, because the
        answer only moves when a sync runs."""
        name = self._ipod_name(params)
        detail = self.get_device({"name": params["name"]}, None, None)
        signature = (name, detail.get("trackCount"), detail.get("freeSpace"))
        cached = getattr(self, "_facet_cache", None)
        if cached and cached[0] == signature:
            return cached[1]
        out = self._script("device_facets", name, timeout=120)
        artists, album_artists, albums, genres = [], [], [], []
        buckets = {"artist": artists, "albumartist": album_artists,
                   "album": albums, "genre": genres}
        for rec in self.itunes.records(out):
            target = buckets.get(rec[0])
            if target is not None:
                target.extend(rec[1:])
        pairs = set()
        for i, album in enumerate(albums):
            who = (album_artists[i] if i < len(album_artists) and album_artists[i].strip()
                   else (artists[i] if i < len(artists) else ""))
            if album.strip():
                pairs.add("%s - %s" % (who.strip(), album.strip()) if who.strip() else album.strip())
        result = {
            "device": name,
            "artists": sorted({a.strip() for a in artists if a.strip()}, key=str.casefold),
            "albums": sorted(pairs, key=str.casefold),
            "genres": sorted({g.strip() for g in genres if g.strip()}, key=str.casefold),
        }
        self._facet_cache = (signature, result)
        return result

    def get_device(self, params, query, body):
        """One device in full: identity, what is on it by category, and its
        playlists. Everything here is read from iTunes or the USB tree; nothing
        is estimated."""
        name = unquote(params["name"])
        devices = self.get_devices({}, None, None)["devices"]
        base = next((d for d in devices if d["name"] == name), None)
        if base is None:
            raise ApiError(404, "no device named %r is connected" % name)
        out = dict(base)
        out.update(self._ipod_prefs(base.get("serialNumber")))
        out["formatName"] = self._format_name(base.get("fileSystem"))
        # "Enable disk use" is not in any preference file, but it is exactly
        # what a mounted volume means, so report that rather than guess.
        out["diskUse"] = bool(base.get("mountPoint"))
        out["hasImage"] = self._device_image_path(out.get("familyId")) is not None
        out["categories"] = []
        out["playlists"] = []
        out["trackCount"] = None
        if not base.get("itunesSource"):
            # A device on the bus that iTunes has not opened as a source. Say
            # so plainly; the page shows the reason instead of empty panels.
            out["unavailableReason"] = (
                "iTunes has not opened %s as a source, so it cannot report what is "
                "on it or sync it." % name
            )
            return out
        recs = self.itunes.records(self._script("device_info", name, timeout=90))
        bit_rates = []
        for r in recs:
            if r[0] == "dev":
                out["capacity"] = self._opt(r[3])
                out["freeSpace"] = self._opt(r[4])
            elif r[0] == "br":
                bit_rates = [int(self._num(x, 0)) for x in (r[1] if len(r) > 1 else "").split(",") if x]
            elif r[0] == "pl":
                pl_name, special = r[1], r[2]
                count = int(self._num(r[3], 0))
                sizes = r[4] if len(r) > 4 else ""
                total = sum(int(self._num(x, 0)) for x in sizes.split(",") if x)
                if special == "Library":
                    out["trackCount"] = count
                elif special != "none":
                    out["categories"].append({"name": special, "trackCount": count,
                                              "bytes": total})
                else:
                    out["playlists"].append({"name": pl_name, "count": count})
        order = {n: i for i, n in enumerate(self.CATEGORY_ORDER)}
        out["categories"].sort(key=lambda c: (order.get(c["name"], 99), c["name"]))
        out["sync"] = self._sync_view(out, bit_rates)
        cap, free = out.get("capacity"), out.get("freeSpace")
        known = sum(c["bytes"] for c in out["categories"])
        if cap is not None and free is not None:
            # Everything iTunes does not account for: artwork, the device's own
            # database, calendars, notes. Never negative.
            out["otherBytes"] = max(0, cap - free - known)
            out["usedBytes"] = cap - free
        return out

    # The bit rates iTunes offers in "Convert higher bit rate songs to".
    CONVERT_RATES = (128, 160, 192, 256)

    # The stock Summary options, in iTunes' own order, and whether this daemon
    # can say anything true about each one.
    STOCK_OPTIONS = (
        ("openOnConnect", "Open iTunes when this iPod is connected"),
        ("syncOnlyChecked", "Sync only checked songs and videos"),
        ("convertBitRate", "Convert higher bit rate songs to AAC"),
        ("manualManagement", "Manually manage music and videos"),
        ("diskUse", "Enable disk use"),
    )

    @staticmethod
    def _detect_convert_rate(bit_rates):
        """The conversion cap, read off what is actually on the device.

        iTunes keeps the setting in its library database, out of reach of
        AppleScript, the preference files and the accessibility tree — iTunes
        12's window reports zero UI elements. But converting to N kbps leaves
        a signature: nothing above N, and a large cluster sitting exactly on
        it while lower-rate files pass through untouched.
        """
        rates = [b for b in bit_rates if b > 0]
        if len(rates) < 20:
            return None
        top = max(rates)
        if top not in Api.CONVERT_RATES:
            return None
        at_cap = sum(1 for b in rates if b == top)
        if at_cap * 4 < len(rates):        # fewer than a quarter: not a cap
            return None
        return {"kbps": top, "sampled": len(rates), "atCap": at_cap}

    def _sync_view(self, detail, bit_rates):
        """What can honestly be said about how this device syncs."""
        lib = self.store.lib
        by_name = {}
        for p in lib.playlist_summaries():
            by_name.setdefault(p["name"], p)
        synced, device_only = [], []
        for p in detail.get("playlists", []):
            match = by_name.get(p["name"])
            if match is None:
                device_only.append(p["name"])
                continue
            synced.append({
                "name": p["name"],
                "playlistId": match["persistentId"],
                "deviceCount": p["count"],
                "libraryCount": match["count"],
                "smart": match["smart"],
            })
        synced.sort(key=lambda p: p["name"].casefold())
        music = next((c for c in detail.get("categories", []) if c["name"] == "Music"), None)
        on_device = music["trackCount"] if music else 0
        # Every music track in the library against what reached the device.
        whole_library = on_device >= len(lib.tracks) - 1
        return {
            "mode": "entireLibrary" if whole_library else "selectedPlaylists",
            "songsOnDevice": on_device,
            "songsInLibrary": len(lib.tracks),
            "convert": self._detect_convert_rate(bit_rates),
            "playlists": synced,
            "deviceOnlyPlaylists": device_only,
            # Everything iTunes keeps to itself, named so the page can say so
            # rather than showing a switch that does nothing.
            "unreadable": [label for key, label in self.STOCK_OPTIONS
                           if key in ("openOnConnect", "syncOnlyChecked", "manualManagement")],
        }

    @staticmethod
    def _opt(raw):
        v = Api._num(raw, -1)
        return None if v < 0 else int(v)

    def _ipod_name(self, params):
        name = unquote(params["name"])
        sources = self.get_sources(params, None, None)["sources"]
        if not any(s["name"] == name and s["kind"] == "iPod" for s in sources):
            raise ApiError(404, "no iPod source named %r is connected" % name)
        return name

    def post_source_sync(self, params, query, body):
        """Fires `update`. Section 7: report the verbatim result, no progress bar."""
        name = self._ipod_name(params)
        out = self._script("ipod_sync", name, timeout=60)
        if self.write_log:
            self.write_log.record("ipod-sync", name, None, None, "ok", out)
        return {"source": name, "result": out}

    def post_source_eject(self, params, query, body):
        name = self._ipod_name(params)
        out = self._script("ipod_eject", name, timeout=60)
        if self.write_log:
            self.write_log.record("ipod-eject", name, None, None, "ok", out)
        return {"source": name, "result": out}

    # -- outputs (AirPlay) ----------------------------------------------

    def get_outputs(self, params, query, body):
        recs = self.itunes.records(self._script("outputs_list", timeout=20))
        outputs = []
        for r in recs:
            if len(r) < 6:
                continue
            outputs.append({
                "name": r[0],
                "kind": r[1],
                "selected": self._bool(r[2]),
                "active": self._bool(r[3]),
                "available": self._bool(r[4]),
                "volume": self._num(r[5], -1),
            })
        return {"outputs": outputs}

    def post_outputs(self, params, query, body):
        names = (body or {}).get("names")
        if not isinstance(names, list) or not names or not all(isinstance(n, str) and n for n in names):
            raise ApiError(400, "body needs a non-empty list of device names")
        # Picking an AirPlay device iTunes cannot use raises a modal dialog on
        # the MacBook Pro, and the script then waits on it. A short timeout
        # keeps that from holding the Apple Events lock for the whole 30 s and
        # freezing every other request behind it; the alert reader, which no
        # longer takes the lock, surfaces the dialog so it can be dismissed.
        try:
            self._script("outputs_set", *names, timeout=8)
        except ApiError as e:
            if e.status == 504:
                alert = self.get_alert({}, {}, None).get("alert")
                message = ("iTunes did not answer within 8 seconds. It is showing: %s"
                           % alert["message"]) if alert else (
                           "iTunes did not answer within 8 seconds; it may be showing a dialog.")
                raise ApiError(504, message)
            raise
        return self.get_outputs(params, query, body)

    # -- playlists -------------------------------------------------------

    def _track_ids(self, body):
        ids = (body or {}).get("ids")
        if not isinstance(ids, list) or not ids:
            raise ApiError(400, "body needs a non-empty ids list")
        if len(ids) > 5000:
            raise ApiError(400, "at most 5000 tracks per request")
        out, seen = [], set()
        for raw in ids:
            if not isinstance(raw, str) or not re.match(r"^[0-9A-Fa-f]{16}$", raw):
                raise ApiError(400, "ids must be 16-character persistent IDs")
            p = raw.upper()
            if p in seen:
                continue
            seen.add(p)
            out.append(p)
        return out

    def _playlist(self, persistent_id):
        p = self.store.lib.playlists_by_id.get(persistent_id)
        if p is None:
            raise ApiError(404, "no such playlist")
        if p.get("smart"):
            raise ApiError(409, "smart playlists cannot be edited")
        return p

    def post_playlist(self, params, query, body):
        name = (body or {}).get("name")
        if not isinstance(name, str) or not name.strip():
            raise ApiError(400, "body needs a name")
        name = name.strip()
        if len(name) > 200:
            raise ApiError(400, "name is too long")
        out = self.itunes.fields(self._script("playlist_create", name, timeout=30))
        if len(out) < 2 or not out[0]:
            raise ApiError(502, "iTunes did not return a playlist id")
        entry = self.store.playlist_op("create", out[0], name=out[1])
        if self.write_log:
            self.write_log.record("playlist-create", out[0], None, {"name": out[1]}, "ok")
        return {k: v for k, v in entry.items() if k != "items"}

    def patch_playlist(self, params, query, body):
        playlist_pid = params["pid"].upper()
        self._playlist(playlist_pid)
        name = (body or {}).get("name")
        if not isinstance(name, str) or not name.strip():
            raise ApiError(400, "body needs a name")
        name = name.strip()[:200]
        old = self._script("playlist_rename", playlist_pid, name, timeout=30)
        entry = self.store.playlist_op("rename", playlist_pid, name=name)
        if self.write_log:
            self.write_log.record("playlist-rename", playlist_pid, {"name": old}, {"name": name}, "ok")
        return {k: v for k, v in entry.items() if k != "items"}

    def delete_playlist(self, params, query, body):
        playlist_pid = params["pid"].upper()
        playlist = self._playlist(playlist_pid)
        name = self._script("playlist_delete", playlist_pid, timeout=30)
        self.store.playlist_op("delete", playlist_pid)
        if self.write_log:
            self.write_log.record("playlist-delete", playlist_pid, {"name": playlist["name"]}, None, "ok", name)
        return {"deleted": playlist_pid, "name": name}

    def _playlist_track_op(self, script, operation, playlist_pid, body):
        playlist = self._playlist(playlist_pid)
        pids = self._track_ids(body)
        missing = [p for p in pids if p not in self.store.lib.tracks]
        if missing:
            raise ApiError(404, "no such track: %s" % missing[0])

        results, ok = [], []
        for start in range(0, len(pids), self.WRITE_CHUNK):
            chunk = pids[start:start + self.WRITE_CHUNK]
            try:
                out = self._script(script, playlist_pid, *chunk, timeout=30 + 1.0 * len(chunk))
            except ApiError as e:
                state = "unknown" if e.status == 504 else "error"
                for p in chunk:
                    results.append({"persistentId": p, "result": state, "detail": e.message})
                continue
            for record in self.itunes.records(out):
                if len(record) >= 2 and record[1] == "ok":
                    ok.append(record[0])
                    results.append({"persistentId": record[0], "result": "ok"})
                else:
                    detail = record[2] if len(record) > 2 else "unknown error"
                    results.append({"persistentId": record[0], "result": "error", "detail": detail})

        if ok:
            self.store.playlist_op("add" if operation == "add" else "remove", playlist_pid, track_ids=ok)
        if self.write_log:
            self.write_log.record_batch("playlist-" + operation, len(pids),
                                        {"playlist": playlist["name"]},
                                        "%d ok, %d failed" % (len(ok), len(pids) - len(ok)))
        return {
            "playlist": {k: v for k, v in self._playlist(playlist_pid).items() if k != "items"},
            "requested": len(pids),
            "changed": len(ok),
            "failed": len(pids) - len(ok),
            "results": results,
        }

    def post_playlist_tracks(self, params, query, body):
        return self._playlist_track_op("playlist_add", "add", params["pid"].upper(), body)

    def delete_playlist_tracks(self, params, query, body):
        return self._playlist_track_op("playlist_remove", "remove", params["pid"].upper(), body)

    # -- metadata writes -------------------------------------------------

    def _script_value(self, internal_name, value):
        """The text form handed to AppleScript as an argv item."""
        if internal_name in self.BOOL_FIELDS:
            return "true" if value else "false"
        if internal_name in self.NUMERIC_FIELDS:
            if value in (None, ""):
                return "0"
            try:
                return str(int(value))
            except (TypeError, ValueError):
                raise ApiError(400, "%s must be a number" % internal_name)
        if value is None:
            return ""
        if not isinstance(value, str):
            raise ApiError(400, "%s must be text" % internal_name)
        return value

    def _memory_value(self, internal_name, value):
        """The typed form stored in the in-memory library."""
        if internal_name in self.BOOL_FIELDS:
            if isinstance(value, str):
                return value.strip().lower() == "true"
            return bool(value)
        if internal_name in self.NUMERIC_FIELDS:
            if value in (None, ""):
                return None
            n = int(value)
            return None if n == 0 else n
        return value or ""

    def patch_tracks(self, params, query, body):
        body = body or {}
        ids = body.get("ids")
        fields = body.get("fields")
        if not isinstance(ids, list) or not ids:
            raise ApiError(400, "body needs a non-empty ids list")
        if not isinstance(fields, dict) or not fields:
            raise ApiError(400, "body needs a non-empty fields object")
        if len(ids) > 5000:
            raise ApiError(400, "at most 5000 tracks per request")

        seen = set()
        pids = []
        for raw in ids:
            if not isinstance(raw, str) or not re.match(r"^[0-9A-Fa-f]{16}$", raw):
                raise ApiError(400, "ids must be 16-character persistent IDs")
            pid = raw.upper()
            if pid in seen:
                continue
            if pid not in self.store.lib.tracks:
                raise ApiError(404, "no such track: %s" % pid)
            seen.add(pid)
            pids.append(pid)

        ordered = []
        for api_name, value in fields.items():
            internal = self.API_FIELDS.get(api_name)
            if internal is None:
                raise ApiError(400, "field not editable: %s" % api_name)
            ordered.append((api_name, internal, value))

        head = [str(len(ordered))]
        for _, internal, value in ordered:
            head.append(Track.EDITABLE[internal])
            head.append(self._script_value(internal, value))

        new_values = {api: value for api, _, value in ordered}
        results = []
        applied = {}
        failures = 0

        for start in range(0, len(pids), self.WRITE_CHUNK):
            chunk = pids[start:start + self.WRITE_CHUNK]
            timeout = 30 + 1.0 * len(chunk)
            try:
                out = self._script("set_fields", *(head + chunk), timeout=timeout)
            except ApiError as e:
                # A timeout means the Apple Event may still be running inside
                # iTunes, so the outcome is unknown rather than failed.
                state = "unknown" if e.status == 504 else "error"
                for pid in chunk:
                    failures += 1
                    results.append({"persistentId": pid, "result": state, "detail": e.message})
                    if self.write_log:
                        self.write_log.record("set", pid, None, new_values, state, e.message)
                continue

            for record in self.itunes.records(out):
                pid = record[0]
                status = record[1] if len(record) > 1 else "error"
                if status == "ok" and len(record) >= 2 + len(ordered):
                    old = {}
                    for i, (api_name, internal, _) in enumerate(ordered):
                        old[api_name] = self._memory_value(internal, record[2 + i]) \
                            if internal in self.NUMERIC_FIELDS or internal in self.BOOL_FIELDS else record[2 + i]
                    applied[pid] = {internal: self._memory_value(internal, value)
                                    for _, internal, value in ordered}
                    results.append({"persistentId": pid, "result": "ok", "old": old})
                    if self.write_log:
                        self.write_log.record("set", pid, old, new_values, "ok")
                else:
                    failures += 1
                    detail = record[2] if len(record) > 2 else "unknown error"
                    results.append({"persistentId": pid, "result": "error", "detail": detail})
                    if self.write_log:
                        self.write_log.record("set", pid, None, new_values, "error", detail)

        if applied:
            # One re-sort for the whole batch, and none at all for a genre edit.
            self.store.patch_many(applied)
        if self.write_log:
            self.write_log.record_batch("set-batch", len(pids), new_values,
                                        "%d ok, %d failed" % (len(applied), failures))
        return {
            "requested": len(pids),
            "updated": len(applied),
            "failed": failures,
            "results": results,
        }


class Handler(BaseHTTPRequestHandler):
    server_version = "iTunesRemote/0.2"
    protocol_version = "HTTP/1.1"
    api = None  # set by make_server

    def log_message(self, fmt, *args):
        log.debug("%s " + fmt, self.address_string(), *args)

    def _authorized(self, query):
        auth = self.headers.get("Authorization", "")
        token = self.headers.get("X-Auth-Token", "")
        if auth.startswith("Bearer "):
            token = auth[7:].strip()
        if not token:
            token = (query.get("token") or [""])[0]
        return token and token == self.api.config.token

    def _send_file(self, response):
        try:
            size = os.path.getsize(response.path)
            f = open(response.path, "rb")
        except OSError:
            self._send(404, {"error": "file unreadable"})
            return
        start, end = 0, size - 1
        status = 200
        rng = self.headers.get("Range", "")
        if rng.startswith("bytes="):
            spec = rng[6:].split(",")[0].strip()
            a, _, b = spec.partition("-")
            try:
                if a:
                    start = int(a)
                    end = int(b) if b else size - 1
                elif b:
                    start = max(0, size - int(b))
            except ValueError:
                start, end = 0, size - 1
            end = min(end, size - 1)
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % size)
                self.send_header("Content-Length", "0")
                self.end_headers()
                f.close()
                return
            status = 206
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", response.content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        if status == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        if self.command == "HEAD":
            f.close()
            return
        try:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(256 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)
        except OSError as e:
            # The player seeked, paused or stopped and dropped the socket.
            # Normal, and not always a BrokenPipeError: macOS raises a bare
            # OSError 41 (protocol wrong type for socket) here, which was
            # filling the log with tracebacks on every seek.
            log.debug("audio stream closed early: %s", e)
        finally:
            f.close()

    # JSON above this size is gzipped for a client that accepts it. The whole
    # library is 21 MB of very repetitive text; level 1 takes a fraction of a
    # second on the MacBook Pro and cuts the transfer to a few MB.
    GZIP_MIN = 16 * 1024

    def _send_bytes(self, status, content_type, data, headers=None):
        encoding = None
        if (len(data) >= self.GZIP_MIN and content_type.startswith("application/json")
                and "gzip" in self.headers.get("Accept-Encoding", "")):
            data = gzip.compress(data, compresslevel=1)
            encoding = "gzip"
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        if encoding:
            self.send_header("Content-Encoding", encoding)
            self.send_header("Vary", "Accept-Encoding")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _send(self, status, payload):
        self._send_bytes(status, "application/json; charset=utf-8", json.dumps(payload).encode("utf-8"))

    def _handle(self, method):
        try:
            parts = urlsplit(self.path)
            query = parse_qs(parts.query, keep_blank_values=True)
            if not self._authorized(query):
                raise ApiError(401, "missing or bad token")
            body = None
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except ValueError:
                    raise ApiError(400, "body is not valid JSON")
            result = self.api.dispatch(method, parts.path, query, body)
            if isinstance(result, FileResponse):
                self._send_file(result)
                return
            if isinstance(result, RawResponse):
                etag = result.headers.get("ETag")
                if etag and self.headers.get("If-None-Match") == etag:
                    self.send_response(304)
                    self.send_header("ETag", etag)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                self._send_bytes(200, result.content_type, result.data, result.headers)
            else:
                self._send(200, result)
        except ApiError as e:
            self._send(e.status, {"error": e.message})
        except Exception as e:  # never let a bug take the server down
            log.exception("unhandled error on %s %s", method, self.path)
            self._send(500, {"error": "internal error: %s" % e})

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def do_PATCH(self):
        self._handle("PATCH")

    def do_DELETE(self):
        self._handle("DELETE")

    def do_HEAD(self):
        self._handle("GET")


def make_server(api):
    handler = type("BoundHandler", (Handler,), {"api": api})
    server = ThreadingHTTPServer((api.config.host, api.config.port), handler)
    server.daemon_threads = True
    return server
