"""Env parsing + validation. Per spec §4.1.

On any invalid/missing input: prints one line to stderr and sys.exit(2).
No traceback. No defaults for credentials. Defaults only for poll/window.
"""
import os
import re
import sys
from dataclasses import dataclass


# Identifier regex — used for both DDL identifiers (TABLE_PREFIX, INFLUX_TAG_KEY)
# so they can be safely interpolated into SQL/Flux.
_PREFIX_RE = re.compile(r"^[a-z][a-z0-9_]{0,30}$")
# General Flux/Influx string regex.
_FLUX_STR_RE = re.compile(r"^[A-Za-z0-9_\-./]{1,128}$")
# Tag value regex — slightly tighter length.
_TAG_VALUE_RE = re.compile(r"^[A-Za-z0-9_\-./]{1,64}$")
_URL_RE = re.compile(r"^https?://[A-Za-z0-9.\-]+(:[0-9]+)?$")


@dataclass(frozen=True)
class Config:
    table_prefix: str
    influx_url: str
    influx_token: str         # never logged
    influx_org: str
    influx_bucket: str
    influx_measurement: str
    influx_field: str
    influx_tag_key: str
    influx_tag_values: tuple[str, ...]   # ordered, deduplicated
    mysql_host: str
    mysql_port: int
    mysql_user: str
    mysql_password: str       # never logged
    mysql_db: str
    poll_interval_seconds: int
    query_window_seconds: int


def _fail(var: str, reason: str) -> None:
    print(f"config_error: {var}: {reason}", file=sys.stderr)
    sys.exit(2)


def _required(var: str) -> str:
    val = os.environ.get(var)
    if val is None or val == "":
        _fail(var, "missing")
    return val  # type: ignore[return-value]


def _matches(var: str, value: str, pattern: re.Pattern) -> None:
    if not pattern.match(value):
        _fail(var, "regex")


def _int_in_range(var: str, default: int | None, lo: int, hi: int) -> int:
    raw = os.environ.get(var)
    if raw is None or raw == "":
        if default is None:
            _fail(var, "missing")
        return default  # type: ignore[return-value]
    try:
        n = int(raw)
    except ValueError:
        _fail(var, "not_int")
        return 0  # unreachable; satisfies type checker
    if not (lo <= n <= hi):
        _fail(var, "range")
    return n


def load_config() -> Config:
    table_prefix = _required("TABLE_PREFIX")
    _matches("TABLE_PREFIX", table_prefix, _PREFIX_RE)

    influx_url = _required("INFLUX_URL")
    _matches("INFLUX_URL", influx_url, _URL_RE)

    influx_token = _required("INFLUX_TOKEN")
    if len(influx_token) < 16:
        _fail("INFLUX_TOKEN", "too_short")

    influx_org = _required("INFLUX_ORG")
    _matches("INFLUX_ORG", influx_org, _FLUX_STR_RE)

    influx_bucket = _required("INFLUX_BUCKET")
    _matches("INFLUX_BUCKET", influx_bucket, _FLUX_STR_RE)

    influx_measurement = _required("INFLUX_MEASUREMENT")
    _matches("INFLUX_MEASUREMENT", influx_measurement, _FLUX_STR_RE)

    influx_field = _required("INFLUX_FIELD")
    _matches("INFLUX_FIELD", influx_field, _FLUX_STR_RE)

    influx_tag_key = _required("INFLUX_TAG_KEY")
    _matches("INFLUX_TAG_KEY", influx_tag_key, _PREFIX_RE)

    raw_values = _required("INFLUX_TAG_VALUES")
    parts = [p.strip() for p in raw_values.split(",") if p.strip()]
    if not parts:
        _fail("INFLUX_TAG_VALUES", "empty")
    if len(parts) > 64:
        _fail("INFLUX_TAG_VALUES", "too_many")
    seen: list[str] = []
    for p in parts:
        if not _TAG_VALUE_RE.match(p):
            _fail("INFLUX_TAG_VALUES", f"regex:{p}")
        if p not in seen:
            seen.append(p)

    mysql_host = _required("MYSQL_HOST")
    mysql_port = _int_in_range("MYSQL_PORT", 3306, 1, 65535)
    mysql_user = _required("MYSQL_USER")
    mysql_password = _required("MYSQL_PASSWORD")
    mysql_db = _required("MYSQL_DB")

    poll_interval_seconds = _int_in_range("POLL_INTERVAL_SECONDS", 10, 5, 3600)
    query_window_seconds = _int_in_range("QUERY_WINDOW_SECONDS", 20, 1, 86400)
    if query_window_seconds < 2 * poll_interval_seconds:
        _fail("QUERY_WINDOW_SECONDS", "range")

    return Config(
        table_prefix=table_prefix,
        influx_url=influx_url,
        influx_token=influx_token,
        influx_org=influx_org,
        influx_bucket=influx_bucket,
        influx_measurement=influx_measurement,
        influx_field=influx_field,
        influx_tag_key=influx_tag_key,
        influx_tag_values=tuple(seen),
        mysql_host=mysql_host,
        mysql_port=mysql_port,
        mysql_user=mysql_user,
        mysql_password=mysql_password,
        mysql_db=mysql_db,
        poll_interval_seconds=poll_interval_seconds,
        query_window_seconds=query_window_seconds,
    )
