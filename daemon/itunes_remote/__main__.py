"""python3 -m itunes_remote [--config PATH] [--init-config] [--xml PATH] [--port N]"""

import argparse
import logging
import logging.handlers
import os
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
    args = ap.parse_args(argv)

    if args.init_config:
        try:
            values = config_mod.write_default(args.config)
        except FileExistsError:
            print("refusing to overwrite existing %s" % args.config, file=sys.stderr)
            return 1
        print("wrote %s" % args.config)
        print("token: %s" % values["token"])
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
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        store.stop()
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
