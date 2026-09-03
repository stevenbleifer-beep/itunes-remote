"""Daemon configuration: a small JSON file, nothing else."""

import json
import os
import secrets

DEFAULT_CONFIG_PATH = os.path.expanduser(
    "~/Library/Application Support/iTunesRemote/config.json"
)

DEFAULTS = {
    "host": "0.0.0.0",
    "port": 8765,
    "token": "",
    "xml_path": "~/Music/iTunes/iTunes Music Library.xml",
    "log_dir": "~/Library/Logs/iTunesRemote",
    "poll_interval": 5,
    "applescript_timeout": 120,
}


class Config(object):
    def __init__(self, values):
        merged = dict(DEFAULTS)
        merged.update(values)
        self.host = merged["host"]
        self.port = int(merged["port"])
        self.token = merged["token"]
        self.xml_path = os.path.expanduser(merged["xml_path"])
        self.log_dir = os.path.expanduser(merged["log_dir"])
        self.poll_interval = float(merged["poll_interval"])
        self.applescript_timeout = float(merged["applescript_timeout"])
        if not self.token:
            raise ValueError("config has no token; run with --init-config first")


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        return Config(json.load(f))


def write_default(path):
    """Create a config with a fresh random token. Refuses to overwrite."""
    if os.path.exists(path):
        raise FileExistsError(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    values = dict(DEFAULTS)
    values["token"] = secrets.token_hex(16)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(values, f, indent=2)
        f.write("\n")
    os.chmod(path, 0o600)
    return values
