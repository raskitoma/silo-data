"""Influx Flux query wrapper. Per spec §4.3.

query_window() returns a list of Row; never raises to caller. All errors
become rate-limited JSON log lines and either skip the offending record
(parse/cast errors) or return [] (transport errors).
"""
from datetime import timezone

import urllib3.exceptions
from influxdb_client import InfluxDBClient
from influxdb_client.rest import ApiException

from config import Config
from db import Row
from log import log


_client: InfluxDBClient | None = None


def _ensure_client(cfg: Config) -> InfluxDBClient:
    global _client
    if _client is None:
        _client = InfluxDBClient(
            url=cfg.influx_url,
            token=cfg.influx_token,
            org=cfg.influx_org,
            enable_gzip=True,
            timeout=10_000,
        )
    return _client


def _build_flux(cfg: Config) -> str:
    """Build the canonical Flux query (spec §5.3) from validated config.

    Tag values are rendered as a Flux string-array literal; INFLUX_TAG_KEY
    is interpolated as a record-accessor key. Both are regex-validated upstream.
    """
    tag_values_literal = ", ".join(f'"{v}"' for v in cfg.influx_tag_values)
    return (
        f'tag_values = [{tag_values_literal}]\n\n'
        f'from(bucket: "{cfg.influx_bucket}")\n'
        f'  |> range(start: -{cfg.query_window_seconds}s)\n'
        f'  |> filter(fn: (r) => r["_measurement"] == "{cfg.influx_measurement}")\n'
        f'  |> filter(fn: (r) => r["_field"] == "{cfg.influx_field}")\n'
        f'  |> filter(fn: (r) => contains(value: r["{cfg.influx_tag_key}"], set: tag_values))\n'
        f'  |> aggregateWindow(every: {cfg.poll_interval_seconds}s, fn: mean, createEmpty: false)\n'
        f'  |> yield(name: "last")'
    )


def query_window(cfg: Config) -> list[Row]:
    flux = _build_flux(cfg)
    try:
        client = _ensure_client(cfg)
        api = client.query_api()
        tables = api.query(query=flux, org=cfg.influx_org)
    except (ApiException, urllib3.exceptions.HTTPError, OSError) as e:
        log("error", level="error", event_subtype="influx_query",
            error_type=type(e).__name__, error_msg=str(e))
        return []

    rows: list[Row] = []
    for table in tables:
        for record in table.records:
            try:
                t = record["_time"].astimezone(timezone.utc).replace(tzinfo=None)
                tag_value = record[cfg.influx_tag_key]
                if tag_value is None:
                    raise KeyError(cfg.influx_tag_key)
                value = float(record["_value"])
                measurement = record["_measurement"]
                field_name = record["_field"]
            except KeyError as e:
                log("error", level="error", event_subtype="influx_parse",
                    error_msg=f"missing_key:{e!s}")
                continue
            except (ValueError, TypeError) as e:
                log("error", level="error", event_subtype="value_cast",
                    error_msg=str(e))
                continue
            rows.append(Row(
                time_recorded=t,
                measurement=measurement,
                field_name=field_name,
                field_value=value,
                tag_value=str(tag_value),
            ))
    return rows
