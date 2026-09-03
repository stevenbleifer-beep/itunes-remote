"""The app's own record of what should be on each device.

iTunes keeps its sync selection in its library database, where nothing outside
iTunes can read or set it, and its window exposes no accessible controls. So
the app does not try to mirror that selection — it keeps one of its own here
and projects it onto a playlist it owns, one playlist per device. A device set
to sync its own playlist then carries exactly what this file says for it.

Plans are keyed by the device's serial number, which is stable and unique.
Steven has five iPods, two of them the same model, so keying on the name would
collide.

Nothing in this module touches iTunes. Writing a playlist is a separate,
explicit step.
"""

import json
import os
import tempfile

KINDS = ("playlist", "artist", "albumartist", "genre", "album")


def default_playlist_name(label):
    """The playlist a device gets. Named after the device so several iPods do
    not fight over one playlist."""
    clean = (label or "iPod").strip() or "iPod"
    return "iPod Sync (%s)" % clean


def _clean(kind, value):
    if kind == "album":
        if isinstance(value, (list, tuple)) and len(value) == 2:
            artist, album = str(value[0]).strip(), str(value[1]).strip()
            return [artist, album] if album else None
        if isinstance(value, str) and value.strip():
            return ["", value.strip()]
        return None
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


class DevicePlan(object):
    """One device's selection."""

    def __init__(self, key, label=None, playlist_name=None, selections=None, owner=None):
        self.key = key
        self.label = label or key
        self.playlist_name = playlist_name or default_playlist_name(self.label)
        self.selections = {k: [] for k in KINDS}
        for kind in KINDS:
            for v in (selections or {}).get(kind, []) or []:
                cleaned = _clean(kind, v)
                if cleaned is not None and cleaned not in self.selections[kind]:
                    self.selections[kind].append(cleaned)
        self._owner = owner

    def to_dict(self):
        return {
            "device": self.key,
            "label": self.label,
            "playlistName": self.playlist_name,
            "selections": {k: list(v) for k, v in self.selections.items()},
            "counts": {k: len(v) for k, v in self.selections.items()},
        }

    def replace(self, playlist_name=None, selections=None, label=None):
        if label:
            self.label = str(label).strip() or self.label
        if playlist_name is not None:
            name = str(playlist_name).strip()
            if not name:
                raise ValueError("playlistName cannot be empty")
            self.playlist_name = name
        if selections is not None:
            if not isinstance(selections, dict):
                raise ValueError("selections must be an object")
            for kind in selections:
                if kind not in KINDS:
                    raise ValueError("not a selectable kind: %s" % kind)
            fresh = {k: [] for k in KINDS}
            for kind in KINDS:
                values = selections.get(kind, self.selections[kind]) or []
                if not isinstance(values, list):
                    raise ValueError("%s must be a list" % kind)
                for v in values:
                    cleaned = _clean(kind, v)
                    if cleaned is not None and cleaned not in fresh[kind]:
                        fresh[kind].append(cleaned)
            self.selections = fresh
        self._save()

    def toggle(self, kind, value, on):
        if kind not in KINDS:
            raise ValueError("not a selectable kind: %s" % kind)
        cleaned = _clean(kind, value)
        if cleaned is None:
            raise ValueError("empty value for %s" % kind)
        current = self.selections[kind]
        if on and cleaned not in current:
            current.append(cleaned)
        elif not on and cleaned in current:
            current.remove(cleaned)
        self._save()
        return cleaned

    def is_empty(self):
        return not any(self.selections.values())

    def spec_lines(self):
        """The tab-separated spec `sync_rebuild.applescript` reads."""
        out = []
        for kind in KINDS:
            for value in self.selections[kind]:
                if kind == "album":
                    out.append("album\t%s\t%s" % (value[0], value[1]))
                else:
                    out.append("%s\t%s" % (kind, value))
        return out

    def write_spec(self, directory=None):
        fd, path = tempfile.mkstemp(prefix="itr-sync-", suffix=".tsv", dir=directory)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(self.spec_lines()))
            f.write("\n")
        return path

    def _save(self):
        if self._owner is not None:
            self._owner.save()


class SyncPlans(object):
    """Every device's plan, in one file."""

    def __init__(self, path):
        self.path = os.path.expanduser(path)
        self.plans = {}
        self.load()

    def load(self):
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                raw = json.load(f)
        except (OSError, ValueError):
            return
        for key, entry in (raw.get("devices") or {}).items():
            self.plans[key] = DevicePlan(key,
                                         label=entry.get("label"),
                                         playlist_name=entry.get("playlistName"),
                                         selections=entry.get("selections"),
                                         owner=self)

    def plan_for(self, key, label=None, create=True):
        """The plan for a device. Created in memory on first ask; it only
        reaches disk once something is actually selected."""
        key = (key or "").strip()
        if not key:
            raise ValueError("a device key is required")
        plan = self.plans.get(key)
        if plan is None:
            if not create:
                return None
            plan = DevicePlan(key, label=label, owner=self)
            self.plans[key] = plan
        elif label and plan.label == plan.key:
            plan.label = label
        return plan

    def to_dict(self):
        return {"devices": {k: p.to_dict() for k, p in self.plans.items()},
                "path": self.path}

    def save(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        payload = {"devices": {}}
        for key, plan in self.plans.items():
            payload["devices"][key] = {
                "label": plan.label,
                "playlistName": plan.playlist_name,
                "selections": plan.selections,
            }
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(self.path), prefix=".sync-")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(payload, f, indent=2, ensure_ascii=False)
                f.write("\n")
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
