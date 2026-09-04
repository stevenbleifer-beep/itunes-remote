"""The only path to iTunes: osascript running a script file with arguments.

Scripts live in daemon/scripts/*.applescript and take their inputs through
`on run argv`, never by string building. Every call is serialized behind
one lock, has a timeout, and refuses to run when iTunes is not up so that
AppleScript can never auto-launch it in the middle of a request.

Scripts return text. Records are separated by ASCII 30, fields by ASCII 31.
"""

import logging
import os
import subprocess
import threading
import time

log = logging.getLogger("itunes_remote.applescript")

RS = "\x1e"
US = "\x1f"

IPOD_MOUNT = "/Volumes/iPod"


class _NoLock(object):
    """A lock-shaped object that locks nothing."""

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class AppleScriptError(Exception):
    """The script ran and iTunes reported an error."""
    status = 502


class AppleScriptTimeout(Exception):
    """osascript was killed. The Apple Event may still complete inside iTunes,
    so callers must treat the outcome as unknown, not failed."""
    status = 504


class ITunesNotRunning(Exception):
    status = 503


class AppleScript(object):
    def __init__(self, scripts_dir, timeout=120.0):
        self.scripts_dir = scripts_dir
        self.timeout = timeout
        self.lock = threading.Lock()

    # -- iTunes process -------------------------------------------------

    _running = (0.0, False)

    @classmethod
    def itunes_running(cls):
        # Asked before every script — the player poll alone once a second —
        # and each ask was a pgrep spawn. Two seconds of memory is plenty:
        # a script against a just-quit iTunes fails on its own anyway.
        at, was = cls._running
        now = time.time()
        if now - at < 2.0:
            return was
        r = subprocess.run(["pgrep", "-x", "iTunes"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls._running = (now, r.returncode == 0)
        return cls._running[1]

    @staticmethod
    def ipod_mounted():
        return os.path.ismount(IPOD_MOUNT)

    def launch_itunes(self, force=False):
        """Opens iTunes. Refuses while an iPod volume is mounted, because that
        has hung iTunes at launch on this machine before — unless `force`,
        which a restart uses: there the iPod being mounted is the normal
        state, and the point is to make iTunes pick it up again."""
        if self.ipod_mounted() and not force:
            raise AppleScriptError(
                "an iPod is mounted at %s; eject it before launching iTunes" % IPOD_MOUNT
            )
        subprocess.run(["open", "-a", "iTunes"], check=False)

    def quit_itunes(self, wait=30):
        """Asks iTunes to quit and waits for it to go. iTunes 12.9.5's device
        handling wedges after an eject that timed out — iPods attach on USB,
        present no disk, and iTunes never lists them — and only a restart of
        iTunes clears it. Quit is a plain Apple Event; no script file needed,
        and it is not serialized behind the lock because the whole point may
        be that iTunes is not answering scripts."""
        subprocess.run(["osascript", "-e", 'tell application "iTunes" to quit'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        for _ in range(wait):
            if not self.itunes_running():
                return True
            time.sleep(1)
        return False

    # -- running scripts ------------------------------------------------

    def run(self, name, *args, **kw):
        """Runs scripts/<name>.applescript with args. Returns stdout text.

        `serialize=False` skips the shared lock. Only for scripts that talk to
        System Events rather than to iTunes: a script waiting on iTunes can be
        blocked for as long as a modal dialog is up there, and reading that
        dialog is exactly what has to keep working while it is.
        """
        timeout = kw.get("timeout") or self.timeout
        require_running = kw.get("require_running", True)
        serialize = kw.get("serialize", True)
        if require_running and not self.itunes_running():
            raise ITunesNotRunning("iTunes is not running on %s" % _computer_name())
        path = os.path.join(self.scripts_dir, name + ".applescript")
        cmd = ["osascript", path] + [str(a) for a in args]
        guard = self.lock if serialize else _NoLock()
        with guard:
            try:
                r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
            except subprocess.TimeoutExpired:
                log.warning("timeout after %.0fs: %s", timeout, name)
                raise AppleScriptTimeout("%s did not finish within %.0f seconds" % (name, timeout))
        if r.returncode != 0:
            err = r.stderr.decode("utf-8", "replace").strip()
            log.warning("%s failed: %s", name, err)
            raise AppleScriptError(_clean_error(err))
        return r.stdout.decode("utf-8", "replace").rstrip("\n")

    @staticmethod
    def records(text):
        """Splits script output into a list of field lists."""
        if not text:
            return []
        return [rec.split(US) for rec in text.split(RS) if rec != ""]

    @staticmethod
    def fields(text):
        return text.split(US)


_name_cache = None


def _computer_name():
    """The Mac's name as System Preferences shows it, for messages."""
    global _name_cache
    if _name_cache is None:
        try:
            out = subprocess.run(["scutil", "--get", "ComputerName"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            _name_cache = out.stdout.decode("utf-8", "replace").strip() or "the other Mac"
        except (OSError, subprocess.SubprocessError):
            _name_cache = "the other Mac"
    return _name_cache


def _clean_error(err):
    # osascript prefixes "path:line:col: execution error: "; keep the message.
    marker = "execution error: "
    i = err.find(marker)
    return err[i + len(marker):] if i >= 0 else err
