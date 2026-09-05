"""Daemon configuration: a small JSON file, nothing else."""

import json
import os
import secrets
import random

DEFAULT_CONFIG_PATH = os.path.expanduser(
    "~/Library/Application Support/iTunesRemote/config.json"
)

DEFAULTS = {
    "host": "0.0.0.0",
    "port": 8765,
    "token": "",
    # Six digits the installer prints; the app trades it for the token over
    # POST /api/pair, so nobody types a 32-character token by hand.
    "pairing_code": "",
    # Which player this Mac has. "iTunes" (12.9.5 on Mojave, read through
    # its XML) or "Music" (Catalina and later, read through musiclibdump).
    # "auto" picks iTunes when /Applications/iTunes.app exists, else Music.
    "app": "auto",
    "xml_path": "~/Music/iTunes/iTunes Music Library.xml",
    # Music.app only: where musiclibdump writes the library plist, and the
    # database file whose change means it is time to write it again.
    "music_library_path": "~/Library/Caches/iTunesRemote/music-library.plist",
    "music_db_path": "~/Music/Music/Music Library.musiclibrary/Library.musicdb",
    "log_dir": "~/Library/Logs/iTunesRemote",
    "poll_interval": 5,
    "applescript_timeout": 120,
    "artwork_cache_dir": "~/Library/Caches/iTunesRemote/artwork",
    # Fill the artwork cache in the background while nothing else is asking.
    # Off means Cover Flow still works; it just exports covers on demand.
    "artwork_warm": True,
    # Seconds of quiet before the warmer will take the Apple Events lock.
    "artwork_warm_idle": 20,
    # The app's own record of what should be on a device. See syncplan.py.
    "sync_plan_path": "~/Library/Application Support/iTunesRemote/sync.json",
}


class Config(object):
    def __init__(self, values, path=None):
        self.path = path
        merged = dict(DEFAULTS)
        merged.update(values)
        self.host = merged["host"]
        self.port = int(merged["port"])
        self.token = merged["token"]
        self.pairing_code = str(merged.get("pairing_code") or "")
        self.app = resolve_app(merged.get("app") or "auto")
        self.xml_path = os.path.expanduser(merged["xml_path"])
        self.music_library_path = os.path.expanduser(merged["music_library_path"])
        self.music_db_path = os.path.expanduser(merged["music_db_path"])
        self.log_dir = os.path.expanduser(merged["log_dir"])
        self.poll_interval = float(merged["poll_interval"])
        self.applescript_timeout = float(merged["applescript_timeout"])
        self.artwork_cache_dir = os.path.expanduser(merged["artwork_cache_dir"])
        self.artwork_warm = bool(merged["artwork_warm"])
        self.artwork_warm_idle = float(merged["artwork_warm_idle"])
        self.sync_plan_path = os.path.expanduser(merged["sync_plan_path"])
        if not self.token:
            raise ValueError("config has no token; run with --init-config first")


ITUNES_APP = "/Applications/iTunes.app"
MUSIC_APPS = ("/System/Applications/Music.app", "/Applications/Music.app")


def resolve_app(value):
    """'iTunes', 'Music', or what this Mac has for 'auto'."""
    value = (value or "auto").strip()
    if value.lower() == "itunes":
        return "iTunes"
    if value.lower() == "music":
        return "Music"
    if os.path.isdir(ITUNES_APP):
        return "iTunes"
    if any(os.path.isdir(p) for p in MUSIC_APPS):
        return "Music"
    return "iTunes"


def app_info_plist(app):
    if app == "Music":
        for p in MUSIC_APPS:
            if os.path.isdir(p):
                return os.path.join(p, "Contents", "Info.plist")
        return os.path.join(MUSIC_APPS[0], "Contents", "Info.plist")
    return os.path.join(ITUNES_APP, "Contents", "Info.plist")


def new_pairing_code():
    return "%06d" % random.SystemRandom().randrange(0, 1000000)


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        values = json.load(f)
    # A config from before pairing existed gets a code the first time it
    # is read, and keeps it.
    if not values.get("pairing_code"):
        values["pairing_code"] = new_pairing_code()
        try:
            with open(path, "w", encoding="utf-8") as f:
                json.dump(values, f, indent=2)
                f.write("\n")
        except OSError:
            pass
    return Config(values, path)


def rotate_pairing_code(cfg):
    """Writes a fresh pairing code into the config file and returns it."""
    code = new_pairing_code()
    if cfg.path:
        try:
            with open(cfg.path, "r", encoding="utf-8") as f:
                values = json.load(f)
            values["pairing_code"] = code
            with open(cfg.path, "w", encoding="utf-8") as f:
                json.dump(values, f, indent=2)
                f.write("\n")
            os.chmod(cfg.path, 0o600)
        except (OSError, ValueError):
            pass
    return code


def write_default(path):
    """Create a config with a fresh random token. Refuses to overwrite."""
    if os.path.exists(path):
        raise FileExistsError(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    values = dict(DEFAULTS)
    values["token"] = secrets.token_hex(16)
    values["pairing_code"] = new_pairing_code()
    with open(path, "w", encoding="utf-8") as f:
        json.dump(values, f, indent=2)
        f.write("\n")
    os.chmod(path, 0o600)
    return values
