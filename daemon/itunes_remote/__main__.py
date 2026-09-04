"""python3 -m itunes_remote [--config PATH] [--init-config] [--xml PATH] [--port N]"""

import argparse
import logging
import logging.handlers
import os
import subprocess
import sys

from . import config as config_mod
from .applescript import AppleScript
from .library import LibraryStore
from .server import Api, make_server
from .writelog import WriteLog


def setup_logging(log_dir):
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    stream = logging.StreamHandler(sys.stderr)
    stream.setFormatter(fmt)
    root.addHandler(stream)
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)
        fh = logging.handlers.RotatingFileHandler(
            os.path.join(log_dir, "daemon.log"), maxBytes=5 * 1024 * 1024, backupCount=5
        )
        fh.setFormatter(fmt)
        root.addHandler(fh)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="itunes_remote")
    ap.add_argument("--config", default=config_mod.DEFAULT_CONFIG_PATH)
    ap.add_argument("--init-config", action="store_true",
                    help="write a config file with a fresh token and exit")
    ap.add_argument("--xml", help="override xml_path from the config")
    ap.add_argument("--port", type=int, help="override port from the config")
    ap.add_argument("--host", help="override host from the config")
    ap.add_argument("--no-log-file", action="store_true")
    ap.add_argument("--pairing-code", action="store_true",
                    help="print the pairing code the app asks for, and exit")
    args = ap.parse_args(argv)

    if args.init_config:
        try:
            values = config_mod.write_default(args.config)
        except FileExistsError:
            print("refusing to overwrite existing %s" % args.config, file=sys.stderr)
            return 1
        print("wrote %s" % args.config)
        print("token: %s" % values["token"])
        print("pairing code: %s" % values["pairing_code"])
        return 0

    try:
        cfg = config_mod.load(args.config)
    except FileNotFoundError:
        print("no config at %s; run with --init-config first" % args.config, file=sys.stderr)
        return 1
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1
    if args.xml:
        cfg.xml_path = os.path.expanduser(args.xml)
    if args.port:
        cfg.port = args.port
    if args.host:
        cfg.host = args.host
    if args.pairing_code:
        print(cfg.pairing_code)
        return 0

    setup_logging(None if args.no_log_file else cfg.log_dir)
    log = logging.getLogger("itunes_remote")

    store = LibraryStore(cfg.xml_path, poll_interval=cfg.poll_interval)
    try:
        store.load()
    except FileNotFoundError as e:
        log.error(str(e))
        return 2
    store.start_watcher()

    scripts_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts")
    itunes = AppleScript(scripts_dir, timeout=cfg.applescript_timeout)
    if not itunes.itunes_running():
        log.warning("iTunes is not running; player and write requests will return 503 until it is")
    api = Api(store, cfg, itunes, WriteLog(cfg.log_dir))
    api.start_artwork_warmer()
    server = make_server(api)
    log.info("listening on http://%s:%d/", cfg.host, cfg.port)
    bonjour = advertise(cfg.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        store.stop()
        server.server_close()
        if bonjour is not None:
            bonjour.terminate()
    return 0


def advertise(port):
    """Registers _itunesremote._tcp with Bonjour through the system's dns-sd,
    so the app finds this Mac by browsing instead of by a typed name. The
    registration lives as long as the child process does."""
    try:
        name = subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        name = ""
    name = name or os.uname().nodename
    try:
        return subprocess.Popen(
            ["/usr/bin/dns-sd", "-R", name, "_itunesremote._tcp", ".", str(port), "protocol=1"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as e:
        logging.getLogger("itunes_remote").warning("Bonjour registration failed: %s", e)
        return None


if __name__ == "__main__":
    sys.exit(main())
