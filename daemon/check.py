#!/usr/bin/env python3
"""Verifies everything SPEC section 9 says will break, one pass/fail per line.

Run on the MacBook Pro:  /usr/local/bin/python3 check.py
Exit status is the number of failures, so setup.sh can chain on it.
"""

import json
import os
import platform
import plistlib
import subprocess
import sys
import time
import urllib.request

# The installer's label, or the development one if that is what is loaded.
LABELS = ["local.itunesremote.daemon", "local.stevenbleifer.itunesremote"]
LABEL = next((l for l in LABELS if os.path.exists(os.path.expanduser("~/Library/LaunchAgents/%s.plist" % l))), LABELS[0])
CONFIG = os.path.expanduser("~/Library/Application Support/iTunesRemote/config.json")
XML = os.path.expanduser("~/Music/iTunes/iTunes Music Library.xml")
PLIST = os.path.expanduser("~/Library/LaunchAgents/%s.plist" % LABEL)
ITUNES_INFO = "/Applications/iTunes.app/Contents/Info.plist"
MUSIC_INFO = next((p for p in ("/System/Applications/Music.app/Contents/Info.plist",
                               "/Applications/Music.app/Contents/Info.plist") if os.path.exists(p)), "")
# Which player this Mac has, the way config.resolve_app decides it.
APP = "iTunes" if os.path.exists(ITUNES_INFO) else ("Music" if MUSIC_INFO else "iTunes")

results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print("%s  %s%s" % ("PASS" if ok else "FAIL", name, ("  (" + detail + ")") if detail else ""))
    return ok


def run(cmd, timeout=20):
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        return r.returncode, r.stdout.decode("utf-8", "replace").strip(), r.stderr.decode("utf-8", "replace").strip()
    except subprocess.TimeoutExpired:
        return -1, "", "timed out"
    except OSError as e:
        return -1, "", str(e)


def main():
    # 1. Interpreter
    v = sys.version_info
    if APP == "iTunes":
        check("Python 3.13 or newer", (v.major, v.minor) >= (3, 13), platform.python_version())
        check("Python is the python.org build", sys.executable.startswith("/Library/Frameworks/Python.framework")
              or sys.executable.startswith("/usr/local/bin"), sys.executable)
    else:
        check("Python 3.9 or newer", (v.major, v.minor) >= (3, 9), platform.python_version())

    # 2. The player
    version = ""
    try:
        with open(ITUNES_INFO if APP == "iTunes" else MUSIC_INFO, "rb") as f:
            version = plistlib.load(f).get("CFBundleShortVersionString", "")
    except (OSError, ValueError):
        pass
    check("%s present" % APP, bool(version), version or "neither /Applications/iTunes.app nor Music.app")
    if APP == "iTunes":
        check("iTunes is 12.9.5", version.startswith("12.9.5"), version)
    rc, _, _ = run(["pgrep", "-x", APP])
    running = rc == 0
    check("%s is running" % APP, running, "launch it, or the daemon returns 503 for player and writes")

    # 3. The library: iTunes' XML, or the musiclibdump tool for Music
    if APP == "iTunes":
        exists = os.path.exists(XML)
        check("Library XML exists", exists, XML if exists else "enable Preferences > Advanced > Share iTunes Library XML")
        if exists:
            age = time.time() - os.path.getmtime(XML)
            check("Library XML written recently", age < 7 * 86400, "%.1f hours old" % (age / 3600))
    else:
        tool = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin", "musiclibdump")
        check("musiclibdump present", os.access(tool, os.X_OK), tool if os.path.exists(tool) else "run daemon/tools/build.sh")

    # 4. Automation permission (TCC). -1743 means the user denied it.
    if running:
        rc, out, err = run(["osascript", "-e", 'tell application "%s" to get version' % APP], timeout=30)
        if rc == 0:
            check("Automation permission for %s" % APP, True, "%s reports %s" % (APP, out))
        elif "-1743" in err:
            check("Automation permission for %s" % APP, False,
                  "denied; allow Python under Security & Privacy > Privacy > Automation")
        else:
            check("Automation permission for %s" % APP, False, err[:120])

    # 5. Accessibility, needed only to read and dismiss the player's own dialogs
    if running:
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts", "alert_read.applescript")
        if APP != "iTunes":
            script = os.path.expanduser("~/Library/Caches/iTunesRemote/scripts-%s/alert_read.applescript" % APP)
        rc, out, err = run(["osascript", script], timeout=25)
        ok = rc == 0
        app = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(sys.executable))),
                           "Resources", "Python.app")
        check("Accessibility permission (optional, for iTunes alerts)", ok,
              "add %s under Security & Privacy > Privacy > Accessibility (the .app, not the binary)" % app
              if not ok else "can read iTunes dialogs")

    # 6. iPod hazard
    if APP == "iTunes":
        check("No iPod volume mounted", not os.path.ismount("/Volumes/iPod"),
              "an iPod in disk mode has hung iTunes at launch before")

    # 7. Config
    cfg = None
    try:
        with open(CONFIG) as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        pass
    check("Config exists with a token", bool(cfg and cfg.get("token")), CONFIG)

    # 8. LaunchAgent
    check("LaunchAgent plist installed", os.path.exists(PLIST), PLIST)
    rc, out, _ = run(["launchctl", "print", "gui/%d/%s" % (os.getuid(), LABEL)])
    check("LaunchAgent loaded", rc == 0, "run setup.sh" if rc != 0 else "")

    # 9. Daemon answering
    if cfg:
        port = cfg.get("port", 8765)
        url = "http://127.0.0.1:%d/api/library" % port
        req = urllib.request.Request(url, headers={"Authorization": "Bearer " + cfg.get("token", "")})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                info = json.load(resp)
            check("Daemon answering on port %d" % port, True,
                  "%d tracks, parsed in %.0f s" % (info.get("trackCount", 0), info.get("parseSeconds", 0)))
        except Exception as e:  # any failure is a fail here
            check("Daemon answering on port %d" % port, False, str(e)[:120])

    failures = sum(1 for _, ok, _ in results if not ok)
    print("\n%d checks, %d failed" % (len(results), failures))
    return failures


if __name__ == "__main__":
    sys.exit(main())
