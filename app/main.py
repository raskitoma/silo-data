"""Bridge entry point. Per spec §4.4.

Loop: ensure_table -> query_window -> insert_rows -> heartbeat -> sleep.
Graceful SIGTERM/SIGINT (current iteration finishes before exit).
Heartbeat file at /tmp/last_poll.json drives the Docker HEALTHCHECK.

Run modes:
    python main.py             # daemon loop
    python main.py --dry-run   # one query, print up to 10 rows + counts, exit 0
"""
import json
import signal
import sys
import time
from collections import Counter
from datetime import datetime, timezone

import db
import influx
import log as _log_mod
from config import load_config
from log import log


HEARTBEAT_PATH = "/tmp/last_poll.json"
DRY_RUN_FLAG = "--dry-run"

_terminate = False


def _on_signal(_signum, _frame):
    global _terminate
    _terminate = True


def _write_heartbeat(last_t: datetime | None) -> None:
    """Best-effort heartbeat. Failure to write must not break the loop."""
    try:
        with open(HEARTBEAT_PATH, "w") as f:
            json.dump({
                "ts": datetime.now(timezone.utc).isoformat(timespec="microseconds"),
                "last_t": last_t.isoformat() if last_t else None,
            }, f)
    except OSError:
        pass


def _interruptible_sleep(seconds: float) -> None:
    """Sleep up to `seconds`, but wake within ~1s of SIGTERM/SIGINT."""
    end = time.monotonic() + seconds
    while not _terminate and time.monotonic() < end:
        time.sleep(min(1.0, end - time.monotonic()))


def _dry_run() -> int:
    cfg = load_config()
    rows = influx.query_window(cfg)
    for r in rows[:10]:
        print(r)
    print(f"TOTAL_ROWS={len(rows)}")
    fields_seen = sorted({r.field_name for r in rows})
    print(f"FIELDS_SEEN={','.join(fields_seen)}")
    return 0


def run() -> int:
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    cfg = load_config()
    db.ensure_table(cfg)  # may sys.exit(2) on auth/db/schema-mismatch

    last_t: datetime | None = None
    log("started",
        prefix=cfg.table_prefix,
        measurement=cfg.influx_measurement,
        fields=list(cfg.influx_fields),
        poll=cfg.poll_interval_seconds,
        window=cfg.query_window_seconds)
    _write_heartbeat(None)

    while not _terminate:
        t0 = time.monotonic()
        try:
            rows = influx.query_window(cfg)
            if last_t is not None:
                rows = [r for r in rows if r.time_recorded > last_t]
            if rows:
                n = db.insert_rows(cfg, rows)
                last_t = max(r.time_recorded for r in rows)
                per_field = Counter(r.field_name for r in rows)
                log("inserted",
                    count=n,
                    latest=last_t.isoformat(),
                    per_field=dict(per_field))
                _log_mod.reset_error_rate_limit()
            else:
                log("idle", window_s=cfg.query_window_seconds)
            _write_heartbeat(last_t)
        except db.TransientDBError as e:
            log("error", level="error", event_subtype="db_transient",
                error_msg=str(e))
        elapsed = time.monotonic() - t0
        _interruptible_sleep(max(0.0, cfg.poll_interval_seconds - elapsed))

    log("shutdown", reason="signal")
    return 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == DRY_RUN_FLAG:
        return _dry_run()
    return run()


if __name__ == "__main__":
    sys.exit(main())
