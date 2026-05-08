"""JSON-line logger with consecutive-error rate limiting (per spec §4.5).

Successive errors with the same `event_subtype` within ERROR_RATE_LIMIT_S are
silently coalesced; the next emitted error carries `suppressed_since_last`.
Successful inserts call reset_error_rate_limit() so a recovery is reflected
on the next emitted error line.
"""
import json
import time
from datetime import datetime, timezone
from typing import Any

ERROR_RATE_LIMIT_S = 60
_error_state: dict[str, dict] = {}


def _utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")


def reset_error_rate_limit() -> None:
    """Clear the error coalescer. Called after each successful insert."""
    _error_state.clear()


def log(event: str, level: str = "info", **kw: Any) -> None:
    """Emit a JSON-line log record. Rate-limits consecutive same-subtype errors."""
    if level == "error":
        key = kw.get("event_subtype", "unspecified")
        now = time.monotonic()
        last = _error_state.get(key)
        if last is not None and now - last["ts"] < ERROR_RATE_LIMIT_S:
            last["count"] += 1
            return
        if last is not None and last["count"] > 0:
            kw = {**kw, "suppressed_since_last": last["count"]}
        _error_state[key] = {"ts": now, "count": 0}
    print(
        json.dumps(
            {"ts": _utc_iso(), "level": level, "event": event, **kw},
            default=str,
        ),
        flush=True,
    )
