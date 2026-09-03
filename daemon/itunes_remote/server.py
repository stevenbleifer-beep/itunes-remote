"""HTTP API. Threaded so reads keep answering while a write is in flight."""

import hashlib
import json
import logging
import os
import plistlib
import re
import tempfile
import threading
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

from . import artwork as artwork_mod
from .applescript import AppleScriptError, AppleScriptTimeout, ITunesNotRunning
from .library import Track

log = logging.getLogger("itunes_remote.server")


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
        "year": "year",
        "trackNumber": "track_number",
        "discNumber": "disc_number",
        "compilation": "compilation",
        "enabled": "enabled",
        "rating": "rating",
    }
    NUMERIC_FIELDS = frozenset(("year", "track_number", "disc_number", "rating"))
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
        pid = r"(?P<pid>[0-9A-Fa-f]{16})"
        self.routes = [
            ("GET", r"/api/library", self.get_library),
            ("GET", r"/api/tracks", self.get_tracks),
            ("GET", r"/api/tracks/" + pid, self.get_track),
            ("GET", r"/api/tracks/" + pid + r"/artwork", self.get_artwork),
            ("GET", r"/api/genres", self.get_genres),
            ("GET", r"/api/artists", self.get_artists),
            ("GET", r"/api/albums", self.get_albums),
            ("GET", r"/api/albumlist", self.get_album_list),
            ("GET", r"/api/playlists", self.get_playlists),
            ("GET", r"/api/playlists/" + pid + r"/tracks", self.get_playlist_tracks),
            ("GET", r"/api/itunes", self.get_itunes),
            ("POST", r"/api/itunes/launch", self.post_itunes_launch),
            ("GET", r"/api/player", self.get_player),
            ("POST", r"/api/player/play", self.post_play),
            ("POST", r"/api/player/(?P<cmd>pause|playpause|next|previous|stop)", self.post_player_cmd),
            ("POST", r"/api/player/volume", self.post_volume),
            ("POST", r"/api/player/shuffle", self.post_shuffle),
            ("POST", r"/api/player/repeat", self.post_repeat),
            ("POST", r"/api/player/position", self.post_position),
            ("GET", r"/api/sources", self.get_sources),
            ("POST", r"/api/sources/(?P<name>[^/]+)/sync", self.post_source_sync),
            ("POST", r"/api/sources/(?P<name>[^/]+)/eject", self.post_source_eject),
            ("GET", r"/api/outputs", self.get_outputs),
            ("POST", r"/api/outputs", self.post_outputs),
            ("PATCH", r"/api/tracks", self.patch_tracks),
            ("POST", r"/api/playlists", self.post_playlist),
            ("POST", r"/api/playlists/" + pid + r"/tracks", self.post_playlist_tracks),
            ("DELETE", r"/api/playlists/" + pid + r"/tracks", self.delete_playlist_tracks),
        ]
        self.compiled = [(m, re.compile("^" + p + "$"), h) for m, p, h in self.routes]

    def dispatch(self, method, path, query, body):
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
        try:
            return self.store.lib.query(offset=offset, limit=limit, compact=compact, **f)
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
        try:
            return {field + "s": self.store.lib.facet(field, **f)}
        except KeyError:
            raise ApiError(404, "no such playlist")

    def get_genres(self, params, query, body):
        return self._facet("genre", query)

    def get_artists(self, params, query, body):
        return self._facet("artist", query)

    def get_albums(self, params, query, body):
        return self._facet("album", query)

    def get_album_list(self, params, query, body):
        f = self._filters(query)
        try:
            return {"albums": self.store.lib.albums(**f)}
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

    def _artwork(self, pid):
        with self.artwork_lock:
            if pid in self.artwork_cache:
                self.artwork_cache.move_to_end(pid)
                return self.artwork_cache[pid]
        t = self.store.lib.tracks.get(pid)
        if t is None:
            raise ApiError(404, "no such track")
        result = None
        if t.location:
            result = artwork_mod.read_embedded(t.location)
        if result is None and self.itunes is not None and self.itunes.itunes_running():
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
        with self.artwork_lock:
            self.artwork_cache[pid] = result
            while len(self.artwork_cache) > self.ARTWORK_CACHE_SIZE:
                self.artwork_cache.popitem(last=False)
        return result

    def get_artwork(self, params, query, body):
        pid = params["pid"].upper()
        result = self._artwork(pid)
        if result is None:
            raise ApiError(404, "no artwork")
        mime, data = result
        etag = '"%s"' % hashlib.sha1(data).hexdigest()[:16]
        return RawResponse(mime, data, {"ETag": etag, "Cache-Control": "max-age=86400"})

    # -- iTunes process -------------------------------------------------

    def get_itunes(self, params, query, body):
        if self.itunes is None:
            return {"running": False, "ipodMounted": False, "configured": False}
        return {
            "running": self.itunes.itunes_running(),
            "ipodMounted": self.itunes.ipod_mounted(),
            "configured": True,
        }

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
        self._script("outputs_set", *names, timeout=30)
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

    def _authorized(self):
        auth = self.headers.get("Authorization", "")
        token = self.headers.get("X-Auth-Token", "")
        if auth.startswith("Bearer "):
            token = auth[7:].strip()
        return token and token == self.api.config.token

    def _send_bytes(self, status, content_type, data, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _send(self, status, payload):
        self._send_bytes(status, "application/json; charset=utf-8", json.dumps(payload).encode("utf-8"))

    def _handle(self, method):
        try:
            if not self._authorized():
                raise ApiError(401, "missing or bad token")
            parts = urlsplit(self.path)
            query = parse_qs(parts.query, keep_blank_values=True)
            body = None
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except ValueError:
                    raise ApiError(400, "body is not valid JSON")
            result = self.api.dispatch(method, parts.path, query, body)
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

    def do_PATCH(self):
        self._handle("PATCH")

    def do_DELETE(self):
        self._handle("DELETE")


def make_server(api):
    handler = type("BoundHandler", (Handler,), {"api": api})
    server = ThreadingHTTPServer((api.config.host, api.config.port), handler)
    server.daemon_threads = True
    return server
