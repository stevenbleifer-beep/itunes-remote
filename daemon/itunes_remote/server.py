"""HTTP API. Threaded so reads keep answering while a write is in flight."""

import hashlib
import json
import logging
import os
import re
import tempfile
import threading
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from . import artwork as artwork_mod
from .applescript import AppleScriptError, AppleScriptTimeout, ITunesNotRunning

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

    def __init__(self, store, config, itunes=None):
        self.store = store
        self.config = config
        self.itunes = itunes
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
            ("GET", r"/api/playlists", self.get_playlists),
            ("GET", r"/api/playlists/" + pid + r"/tracks", self.get_playlist_tracks),
            ("GET", r"/api/itunes", self.get_itunes),
            ("POST", r"/api/itunes/launch", self.post_itunes_launch),
            ("GET", r"/api/player", self.get_player),
            ("POST", r"/api/player/play", self.post_play),
            ("POST", r"/api/player/(?P<cmd>pause|playpause|next|previous|stop)", self.post_player_cmd),
            ("POST", r"/api/player/volume", self.post_volume),
            ("POST", r"/api/player/position", self.post_position),
            ("GET", r"/api/outputs", self.get_outputs),
            ("POST", r"/api/outputs", self.post_outputs),
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
            return float(s) if "." in s else int(s)
        except (ValueError, TypeError):
            return default

    @staticmethod
    def _bool(s):
        return s.strip().lower() == "true"

    # -- library reads --------------------------------------------------

    def get_library(self, params, query, body):
        info = self.store.lib.info()
        info.update(self.store.status())
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
        return state

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
