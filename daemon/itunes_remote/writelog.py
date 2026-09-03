"""The audit log for every mutation, required by SPEC section 6.

One JSON object per line, so a bulk edit can be inspected or reversed by
reading the file back. Rotates at 5 MB, ten files kept, because a few large
bulk edits should never push the history of an earlier one out of reach.
"""

import json
import logging
import logging.handlers
import os
from datetime import datetime, timezone


class WriteLog(object):
    def __init__(self, log_dir):
        self.path = os.path.join(log_dir, "writes.log")
        os.makedirs(log_dir, exist_ok=True)
        self.logger = logging.getLogger("itunes_remote.writes")
        self.logger.propagate = False
        self.logger.setLevel(logging.INFO)
        if not self.logger.handlers:
            handler = logging.handlers.RotatingFileHandler(
                self.path, maxBytes=5 * 1024 * 1024, backupCount=10
            )
            handler.setFormatter(logging.Formatter("%(message)s"))
            self.logger.addHandler(handler)

    def record(self, operation, persistent_id, old, new, result, detail=None):
        entry = {
            "at": datetime.now(timezone.utc).isoformat(),
            "op": operation,
            "track": persistent_id,
            "old": old,
            "new": new,
            "result": result,
        }
        if detail:
            entry["detail"] = detail
        self.logger.info(json.dumps(entry, ensure_ascii=False, sort_keys=True))

    def record_batch(self, operation, count, fields, detail=None):
        entry = {
            "at": datetime.now(timezone.utc).isoformat(),
            "op": operation,
            "trackCount": count,
            "fields": fields,
        }
        if detail:
            entry["detail"] = detail
        self.logger.info(json.dumps(entry, ensure_ascii=False, sort_keys=True))
