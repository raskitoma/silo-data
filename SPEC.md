# SPEC — InfluxDB → MySQL 8.4 Resilient Sync Bridge

**For:** an autonomous coding agent (Open Claude / Claude Code).
**Target host OS:** Ubuntu 22.04 / 24.04 LTS.
**Target stack:** InfluxDB 2.x (Flux) → MySQL 8.4 LTS, via a single Dockerised Python daemon.
**Operator workflow:** one bridge container fans out across all configured silos for a single (measurement, field) pair.
**Mandate:** read §0 in full, then §1, then build §7 milestone-by-milestone. Do not advance past a milestone until every PASS CRITERION holds. Do not invent scope.

---

## 0. Operating Contract — Karpathy Guidelines (binding)

This contract overrides default LLM coding tendencies. Non-negotiable.

### 0.1 Think Before Coding — Surface Assumptions
> *Don't assume. Don't hide confusion. Surface tradeoffs.*

Before each milestone, write a 3–8 line `Assumptions:` note in the commit body listing what was interpreted and what was deferred. If a requirement admits more than one valid reading, **stop and ask**; do not pick silently. §1 is the seed list — extend it as you go.

### 0.2 Simplicity First
> *Minimum code that solves the problem. Nothing speculative.*

No features beyond what is in this spec. No abstractions for single-use code. No retry libraries when a `try/except + sleep` loop suffices. No ORM. No async. No metrics framework. Total Python source target: **≤350 lines**. If you need more, surface why.

### 0.3 Surgical Changes
> *Touch only what you must. Every changed line should trace directly to the user's request.*

Each commit's diff contains only what its milestone requires. No drive-by reformats, no opportunistic dependency upgrades. PR review reads `git log -p` against this rule.

### 0.4 Goal-Driven Execution
> *Define success criteria. Loop until verified.*

Every milestone in §7 is **plan-with-checkpoints** — each implementation step has an inline `→ verify:` clause — and ends in a numbered PASS CRITERIA list of binary, observable checks. Loop (write → run → inspect → fix) until every box is true. Do not weaken a criterion that fails; surface the blocker.

---

## 1. Assumptions Surfaced (review before coding)

Defaults shown in **bold**. These were resolved with the operator. If a future change invalidates one, edit the spec — do not hide the divergence in code.

| # | Question | Resolution |
|---|---|---|
| A1 | "Silo" semantics | **A literal corn silo.** One Influx tag value per silo. Many silos contribute data to the same `_measurement`/`_field`; they are distinguished by the tag value. |
| A2 | Raw points or windowed mean | **Windowed mean** — Flux uses `aggregateWindow(every: ${POLL_INTERVAL_SECONDS}s, fn: mean, createEmpty: false)`. `field_value` therefore stores the per-window mean, never a raw sample. |
| A3 | Window vs. interval timing / dedup | **Both safety nets:** a `UNIQUE KEY` on `(time_recorded, measurement, field_name, <TAG_KEY>)` plus an in-process `last_t` watermark to skip redundant inserts. Inserts use `INSERT IGNORE`. |
| A4 | Time precision | **Microsecond.** Influx ns → MySQL `DATETIME(6)`. Aggregated means do not need ns. |
| A5 | Timezone | **UTC, naive.** README documents this so analysts don't reinterpret. |
| A6 | Networking | **Host LAN.** `network_mode: host` on the bridge service. |
| A7 | Connection pooling | **`pool_size=2`.** Just enough to reconnect cleanly on a transient error. |
| A8 | Init failure policy | **Fail-fast on `Access denied` and `Unknown database` (exit 2). Retry on connection refused / network errors.** Prevents log-spam of unfixable conditions. |
| A9 | Dry-run with zero rows | **Warn-and-proceed if operator confirms.** Empty bucket is a valid first-deploy state. |
| A10 | MySQL auth plugin | **`caching_sha2_password` (MySQL 8.4 default) supported via `mysql-connector-python` 9.x.** README troubleshooting lists symptom + fix. |
| A11 | Stack version | **MySQL 8.4 LTS** (operator confirmed). MariaDB compatibility is preserved at the driver level but not specifically validated. InfluxDB 2.x. |
| A12 | Tag key naming | **Configurable env `INFLUX_TAG_KEY`. The MySQL column uses the same name.** Validated against `^[a-z][a-z0-9_]{0,30}$` so it can be safely interpolated into DDL. |
| A13 | Tag value selection | **Allowlist via env `INFLUX_TAG_VALUES=silo_1,silo_2,silo_3`.** Flux filters with `contains()`. New silos require env update + restart — explicit, no silent fan-out growth. |
| A14 | Schema reset on tag-key change | **Operator-driven `DROP TABLE` + restart.** No automatic migration. Source of truth is Influx; rebuilding the MySQL mirror is cheap. README documents the procedure. |
| A15 | Polling configurability | **`POLL_INTERVAL_SECONDS` env, default 10, range [5, 3600].** `QUERY_WINDOW_SECONDS` default 20, must be ≥ 2 × poll interval. |
| A16 | Liveness vs. process-exit detection | **Heartbeat file `/tmp/last_poll.json` + Docker `HEALTHCHECK`.** A stuck (hung) process is detected externally because `restart: unless-stopped` only fires on actual exits. |
| A17 | Shutdown semantics | **SIGTERM is graceful** — current iteration finishes, heartbeat is written, process exits 0 within ≤1s of receipt. |
| A18 | Sustained-outage log volume | **Rate-limit consecutive same-subtype errors to one line per 60s.** First successful poll after recovery resets the limiter and records `suppressed_since_last`. |
| A19 | Backpressure after outage recovery | **Chunked inserts at 1000 rows/statement.** Guards against `max_allowed_packet` and statement-runtime spikes when a long-outage recovery floods 5–10k rows in one window. |
| A20 | Schema ownership | **The bridge never modifies or destroys existing tables.** It only issues `CREATE TABLE IF NOT EXISTS`, `SELECT` against `information_schema`, and `INSERT IGNORE`. No `DROP`, `TRUNCATE`, `DELETE`, or `ALTER`. On schema mismatch (e.g. `INFLUX_TAG_KEY` was changed and the existing column doesn't match) the bridge fails fast (`sys.exit 2`) with a `db_init` error pointing the admin at the manual reset procedure. Reset is **always** an admin action, performed out-of-band. |

---

## 2. System Overview

```
                 ┌────────────────────────────────────────────┐
                 │  deploy.sh (Ubuntu 22/24, host-side wizard) │
                 │  ─ checks docker / docker compose           │
                 │  ─ prompts (incl. INFLUX_TAG_KEY,           │
                 │     INFLUX_TAG_VALUES allowlist)            │
                 │  ─ persists .env (mode 600), backs up prev. │
                 │  ─ pre-flight: curl Influx /health,         │
                 │                mysql SELECT 1               │
                 │  ─ docker compose build + dry-run           │
                 │  ─ docker compose up -d --build             │
                 └────────────────────┬────────────────────────┘
                                      │
                                      ▼
                        .env  +  docker-compose.yml
                                      │
                                      ▼
   ┌──────────────┐                ┌──────────────┐                ┌──────────────────┐
   │  InfluxDB    │  Flux/HTTP     │  bridge      │   SQL          │  MySQL 8.4       │
   │  (LAN)       │ ◄────────────  │  (Python,    │  ────────────► │  <pre>_ingest_*  │
   │  bucket      │  every Ns      │  stdout=log) │  INSERT IGNORE │  (LAN)           │
   └──────────────┘                └──────────────┘                └──────────────────┘
                                          │
                                          ├──► /tmp/last_poll.json (heartbeat, read by HEALTHCHECK)
                                          │
                                          └──► docker logs (json-file driver, rate-limited errors)
```

Per poll, N rows are inserted where N = `|INFLUX_TAG_VALUES|` (one row per silo). Inserts are chunked at 1000 rows/statement when N is large or after an outage flood.

**Out of scope (do not implement):** historical backfill, multi-bucket fan-in, multi-field/multi-measurement ingestion, auto-discovery of new tag values, Prometheus metrics, web UI, alerting, schema migrations beyond `CREATE TABLE IF NOT EXISTS`, async I/O, custom retry frameworks, k8s artifacts.

---

## 3. Repository Layout (canonical)

```
.
├── app/
│   ├── main.py            # Loop: ensure_table → query_window → insert_rows → heartbeat → sleep
│   ├── db.py              # MySQL pool, ensure_table, insert_rows (chunked)
│   ├── influx.py          # Influx client + query_window
│   ├── config.py          # Env parsing + validation; SystemExit(2) on bad input
│   ├── log.py             # JSON-line logger + error rate-limit
│   ├── requirements.txt
│   └── Dockerfile
├── deploy.sh              # Bash wizard (POSIX bash, set -euo pipefail) + preflight probes
├── docker-compose.yml
├── .env.example           # Documented placeholders (committed)
├── .env                   # Generated by deploy.sh (gitignored, mode 600)
├── .env.bak.<unix-ts>     # Auto-backup written before any Update overwrite (gitignored)
├── .gitignore             # Includes .env and .env.bak.*
└── README.md
```

**Runtime artifact (not committed, not persisted across restarts):** `/tmp/last_poll.json` — heartbeat written by `main.py` after each successful poll, read by the Docker `HEALTHCHECK`.

LOC budgets: **Python ≤350**, **bash ≤200**.

---

## 4. Component Contracts

### 4.1 `config.py`
Single function `load_config() -> Config` returning a frozen `dataclass`. On any invalid/missing input: `print(f"config_error: {VAR}: {reason}", file=sys.stderr); sys.exit(2)`. One line. No traceback.

```python
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
```

**Validation rules**

| Variable | Rule |
|---|---|
| `TABLE_PREFIX` | `^[a-z][a-z0-9_]{0,30}$` |
| `INFLUX_TAG_KEY` | `^[a-z][a-z0-9_]{0,30}$` (same regex — used as DDL identifier) |
| `INFLUX_TAG_VALUES` | comma-separated, each `^[A-Za-z0-9_\-./]{1,64}$`, 1–64 entries, deduplicated preserving order |
| `INFLUX_BUCKET`, `INFLUX_MEASUREMENT`, `INFLUX_FIELD`, `INFLUX_ORG` | `^[A-Za-z0-9_\-./]{1,128}$` |
| `INFLUX_URL` | `^https?://[A-Za-z0-9.\-]+(:[0-9]+)?$` (no trailing `/`) |
| `INFLUX_TOKEN` | length ≥ 16; never logged |
| `MYSQL_HOST` | non-empty |
| `MYSQL_PORT` | int 1–65535, default 3306 |
| `MYSQL_PASSWORD` | non-empty; never logged |
| `POLL_INTERVAL_SECONDS` | int [5, 3600], default 10 |
| `QUERY_WINDOW_SECONDS` | int ≥ 2 × `POLL_INTERVAL_SECONDS`, default 20 |

No operator input ever reaches DDL or Flux unvalidated.

### 4.2 `db.py`
- `pool = MySQLConnectionPool(pool_name="bridge", pool_size=2, ...)`. Two is enough; the loop is single-threaded but a spare lets us reconnect without tearing the pool down.
- `class TransientDBError(Exception)` — raised on retryable errors only.
- `ensure_table(cfg: Config) -> None` first calls `_verify_schema(cfg)` (read-only `SELECT` against `information_schema.COLUMNS`) and then issues exactly the DDL in §5.2 with the validated `<TABLE_PREFIX>` and `<INFLUX_TAG_KEY>` interpolated. Idempotent.
  - **The module never issues `DROP`, `TRUNCATE`, `DELETE`, or `ALTER`. It only ever runs `CREATE TABLE IF NOT EXISTS`, `SELECT` against `information_schema`, and `INSERT IGNORE` (per A20).**
  - `_verify_schema` confirms that, if the table exists, it carries the configured `INFLUX_TAG_KEY` as a column. On mismatch (admin changed the tag key between deploys) it logs one `db_init` error pointing at the README reset procedure and `sys.exit(2)`. The bridge does not attempt to migrate or modify the existing table.
  - On `Access denied`, `Unknown database`, or any `mysql.connector.errors.ProgrammingError` whose errno is in `{1044, 1045, 1049}` → `print` one JSON line and `sys.exit(2)` (per A8).
  - On `OperationalError` / connection refused → raise `TransientDBError`.
- `insert_rows(cfg: Config, rows: list[Row]) -> int` — `INSERT IGNORE INTO ... VALUES (%s, %s, %s, %s, %s)` via `executemany`, **chunked at `INSERT_CHUNK_SIZE = 1000` rows per statement**. Returns affected row count summed across chunks. On `mysql.connector.Error` mid-chunk → log one JSON `error` line via `log.log(...)` (rate-limited per §4.5), return the count from chunks already committed; the loop continues. Chunking prevents `max_allowed_packet` pressure and unbounded statement runtime when a recovery from outage drops 5–10k rows in one window.
- `Row = namedtuple("Row", ["time_recorded", "measurement", "field_name", "field_value", "tag_value"])`. `time_recorded` is a UTC-naive `datetime`.

DDL identifier safety: the table name and tag-column name come from regex-validated config. They are interpolated once (f-string) when `ensure_table` builds its SQL string. Values use `%s` placeholders.

### 4.3 `influx.py`
- `client = InfluxDBClient(url=cfg.influx_url, token=cfg.influx_token, org=cfg.influx_org, enable_gzip=True, timeout=10_000)`.
- `query_window(cfg: Config) -> list[Row]` runs the Flux in §5.3.
- Per-record mapping:
  ```python
  Row(
      time_recorded=record["_time"].astimezone(timezone.utc).replace(tzinfo=None),
      measurement=record["_measurement"],
      field_name=record["_field"],
      field_value=float(record["_value"]),
      tag_value=record[cfg.influx_tag_key],
  )
  ```
- On `ApiException`, `urllib3.exceptions.*`, `KeyError` (missing tag), or `(ValueError, TypeError)` cast failure: log one JSON `error` line via `log.log(...)` (rate-limited) and either skip the offending record (cast/key error) or return `[]` (transport error). **Never raises to caller.**

### 4.4 `main.py`
```python
HEARTBEAT_PATH = "/tmp/last_poll.json"
_terminate = False

def _on_signal(signum, frame):
    global _terminate
    _terminate = True

def _write_heartbeat(last_t: datetime | None) -> None:
    # Best-effort; never break the loop on heartbeat failure.
    try:
        with open(HEARTBEAT_PATH, "w") as f:
            json.dump({
                "ts": datetime.now(timezone.utc).isoformat(timespec="microseconds"),
                "last_t": last_t.isoformat() if last_t else None,
            }, f)
    except OSError:
        pass

def _interruptible_sleep(seconds: float) -> None:
    end = time.monotonic() + seconds
    while not _terminate and time.monotonic() < end:
        time.sleep(min(1.0, end - time.monotonic()))

def run() -> None:
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    cfg = load_config()
    db.ensure_table(cfg)                      # may sys.exit(2); see A8
    last_t: datetime | None = None
    log("started",
        prefix=cfg.table_prefix,
        tag_key=cfg.influx_tag_key,
        tag_values=list(cfg.influx_tag_values),
        poll=cfg.poll_interval_seconds)
    _write_heartbeat(None)                    # initial heartbeat so HEALTHCHECK starts green
    while not _terminate:
        t0 = time.monotonic()
        try:
            rows = influx.query_window(cfg)
            if last_t is not None:
                rows = [r for r in rows if r.time_recorded > last_t]
            if rows:
                n = db.insert_rows(cfg, rows)
                last_t = max(r.time_recorded for r in rows)
                per_tag = Counter(r.tag_value for r in rows)
                log("inserted", count=n, latest=last_t.isoformat(), per_tag=dict(per_tag))
                log_module.reset_error_rate_limit()    # successful poll resets coalescer
            else:
                log("idle", window_s=cfg.query_window_seconds)
            _write_heartbeat(last_t)
        except db.TransientDBError as e:
            log("error", level="error", event_subtype="db_transient", error_msg=str(e))
        elapsed = time.monotonic() - t0
        _interruptible_sleep(max(0.0, cfg.poll_interval_seconds - elapsed))
    log("shutdown", reason="signal")
```

CLI: `python main.py --dry-run` short-circuits after one `query_window()`, prints up to 10 row reprs followed by `TOTAL_ROWS=N` and `TAGS_SEEN=silo_1,silo_2,...`, then `sys.exit(0)`. Dry-run does not write a heartbeat and does not install signal handlers.

### 4.5 `log.py` (≤50 lines)
JSON-line logger with consecutive-error rate limiting. Successive errors with the same `event_subtype` within `ERROR_RATE_LIMIT_S` (60s) are silently coalesced; the next emitted error carries `suppressed_since_last`.

```python
import json, sys, time
from datetime import datetime, timezone
from typing import Any

ERROR_RATE_LIMIT_S = 60
_error_state: dict[str, dict] = {}

def _utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")

def reset_error_rate_limit() -> None:
    _error_state.clear()

def log(event: str, level: str = "info", **kw: Any) -> None:
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
    print(json.dumps(
        {"ts": _utc_iso(), "level": level, "event": event, **kw}, default=str
    ), flush=True)
```

`flush=True` is required; the json-file log driver buffers otherwise. `main.py` calls `reset_error_rate_limit()` after each successful insert so a recovery is immediately reflected in subsequent error lines.

### 4.6 `Dockerfile`
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ .
RUN useradd -u 10001 -r bridge && chown -R bridge /app
USER bridge

# Heartbeat-based liveness. Fails if last_poll.json is missing or older than
# 3 × default poll interval (30s). For deployments that increase
# POLL_INTERVAL_SECONDS substantially, override --interval/--start-period
# in docker-compose.yml.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=2 \
    CMD python -c "import json,os,sys,time;\
p='/tmp/last_poll.json';\
sys.exit(0) if os.path.exists(p) and time.time()-os.path.getmtime(p) < 30 else sys.exit(1)"

ENTRYPOINT ["python", "-u", "main.py"]
```

The healthcheck runs in the container, so `restart: on-failure` would *not* re-trigger on a stuck process. Combined with `restart: unless-stopped` in compose, an unhealthy container stays running but the orchestrator/operator can detect it via `docker compose ps` and `docker inspect --format '{{.State.Health.Status}}'`. A stuck process that exits the loop (e.g., uncaught exception) still triggers the standard restart path.

### 4.7 `requirements.txt` (pinned)
```
influxdb-client==1.49.0
mysql-connector-python==9.4.0
```
Add nothing without an entry in §1 (escalation, not silent change).

### 4.8 `docker-compose.yml`
```yaml
services:
  bridge:
    build: .
    container_name: ${TABLE_PREFIX}_influx_mysql_bridge
    env_file: .env
    restart: unless-stopped
    network_mode: host        # per A6
    stop_grace_period: 15s    # honour graceful SIGTERM (per A17)
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "5" }
```
`COMPOSE_PROJECT_NAME` is set to `${TABLE_PREFIX}` in `.env` so multiple bridges on the same host (different `TABLE_PREFIX`) do not collide. The `HEALTHCHECK` is defined in the Dockerfile (§4.6) and inherited.

---

## 5. Data Contracts

### 5.1 Environment variables (full)

| Variable | Required | Default | Rule | Notes |
|---|---|---|---|---|
| `TABLE_PREFIX` | yes | — | `^[a-z][a-z0-9_]{0,30}$` | Used as DDL identifier prefix. |
| `INFLUX_URL` | yes | — | `^https?://...` | No trailing `/`. |
| `INFLUX_TOKEN` | yes | — | len ≥ 16 | Redacted in logs. |
| `INFLUX_ORG` | yes | — | regex §4.1 | |
| `INFLUX_BUCKET` | yes | — | regex §4.1 | |
| `INFLUX_MEASUREMENT` | yes | — | regex §4.1 | |
| `INFLUX_FIELD` | yes | — | regex §4.1 | |
| `INFLUX_TAG_KEY` | yes | — | `^[a-z][a-z0-9_]{0,30}$` | Used as DDL column name. |
| `INFLUX_TAG_VALUES` | yes | — | comma-sep, regex per item, 1–64 | E.g. `silo_1,silo_2,silo_3`. |
| `MYSQL_HOST` | yes | — | non-empty | |
| `MYSQL_PORT` | no | `3306` | int 1–65535 | |
| `MYSQL_USER` | yes | — | non-empty | |
| `MYSQL_PASSWORD` | yes | — | non-empty | Redacted in logs. |
| `MYSQL_DB` | yes | — | non-empty | |
| `POLL_INTERVAL_SECONDS` | no | `10` | int [5, 3600] | |
| `QUERY_WINDOW_SECONDS` | no | `20` | int ≥ 2 × poll | |
| `COMPOSE_PROJECT_NAME` | auto | `${TABLE_PREFIX}` | set by deploy.sh | Used by docker compose. |

### 5.2 SQL DDL (canonical, with substitutions)

`<pre>` is `${TABLE_PREFIX}`; `<tag>` is `${INFLUX_TAG_KEY}`. Both validated.

```sql
CREATE TABLE IF NOT EXISTS `<pre>_ingest_data` (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    time_recorded   DATETIME(6)   NOT NULL,                       -- UTC, naive (A5)
    measurement     VARCHAR(255)  NOT NULL,
    field_name      VARCHAR(255)  NOT NULL,
    field_value     DOUBLE        NOT NULL,
    `<tag>`         VARCHAR(64)   NOT NULL,                       -- e.g. `silo`
    created_at      TIMESTAMP(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    UNIQUE KEY uq_point (time_recorded, measurement, field_name, `<tag>`),
    KEY idx_time (time_recorded),
    KEY idx_tag_time (`<tag>`, time_recorded)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
```

`utf8mb4_0900_ai_ci` is the MySQL 8.x default; explicit so the table doesn't drift if server defaults change.

### 5.3 Flux query (canonical)

```flux
tag_values = ["${TAG_VAL_1}", "${TAG_VAL_2}", ...]

from(bucket: "${INFLUX_BUCKET}")
  |> range(start: -${QUERY_WINDOW_SECONDS}s)
  |> filter(fn: (r) => r["_measurement"] == "${INFLUX_MEASUREMENT}")
  |> filter(fn: (r) => r["_field"] == "${INFLUX_FIELD}")
  |> filter(fn: (r) => contains(value: r["${INFLUX_TAG_KEY}"], set: tag_values))
  |> aggregateWindow(every: ${POLL_INTERVAL_SECONDS}s, fn: mean, createEmpty: false)
  |> yield(name: "last")
```

Substitution is done in Python from validated config; no operator string ever reaches Flux unvalidated.

### 5.4 Log line schema

One JSON object per line on stdout. Mandatory keys: `ts` (ISO-8601 UTC, microseconds), `level` (`info|warn|error`), `event` (snake_case). Event-specific keys allowed. `INFLUX_TOKEN` and `MYSQL_PASSWORD` are forbidden in any log line.

Canonical events:
- `started` — `{ prefix, tag_key, tag_values, poll }`
- `inserted` — `{ count, latest, per_tag }` — emitted on every successful insert; resets the error rate-limiter.
- `idle` — `{ window_s }` — Influx returned no rows in this poll.
- `error` — `{ event_subtype, error_msg, [suppressed_since_last] }` where `event_subtype ∈ {influx_query, influx_parse, db_transient, db_init, value_cast}`. The `suppressed_since_last` count appears on the first error after a rate-limit window ended (per A18).
- `shutdown` — `{ reason: "signal" }` — emitted once after SIGTERM/SIGINT before exit (per A17).

Only unhandled exceptions get a Python traceback. Handled errors are one-line JSON.

---

## 6. `deploy.sh` Behaviour (Ubuntu 22/24)

POSIX `#!/usr/bin/env bash`, `set -euo pipefail`. `shellcheck deploy.sh` must report **zero** warnings.

### 6.1 Order of operations
1. **Dependency check.** `command -v docker` and `docker compose version`. On miss → install hint pointing to `https://docs.docker.com/engine/install/ubuntu/` and `exit 1`.
2. **State awareness.** If `.env` exists → prompt `(1) Reuse  (2) Update  (3) Cancel`. `1` skips to step 5. `3` exits 0.
3. **Prompts** (each with default in `[xxxx…last4]` format on Update mode; tokens/passwords via `read -rs`):
   - `TABLE_PREFIX`, `INFLUX_URL`, `INFLUX_TOKEN`, `INFLUX_ORG`, `INFLUX_BUCKET`, `INFLUX_MEASUREMENT`, `INFLUX_FIELD`
   - `INFLUX_TAG_KEY` (e.g. `silo`)
   - `INFLUX_TAG_VALUES` — multi-prompt: keeps asking "Add another tag value? (Enter to finish)" until empty input. Each entered value is regex-validated; invalid entries are rejected with a one-line message and re-prompted.
   - `MYSQL_HOST`, `MYSQL_PORT` (default 3306), `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DB`
   - `POLL_INTERVAL_SECONDS` (default 10), `QUERY_WINDOW_SECONDS` (default 20)
4. **Persist.** *In Update mode only:* `cp .env ".env.bak.$(date +%s)"` before overwrite (per "auto-backup" requirement). Then write new `.env`, `chmod 600 .env`. `COMPOSE_PROJECT_NAME=${TABLE_PREFIX}` is added automatically.
5. **Pre-flight probes.** *Before* the dry-run, validate connectivity in isolation so failures are unambiguous:
   - `curl -fsS --max-time 5 "$INFLUX_URL/health"` — expect 200 with `{"status":"pass"}`. On failure, print the `curl` exit code and stderr, **abort before docker compose build**.
   - `docker run --rm --network host mysql:8.4 mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1" "$MYSQL_DB"` — expect `1`. On failure, print stderr, abort.
   - Either probe failing exits the wizard with code 3 (distinct from missing-deps `1` and config-error `2`); the bridge image is **not** built.
6. **Build & dry-run.** `docker compose build` then `docker compose run --rm bridge python -u main.py --dry-run`. Show output. Prompt `Proceed with deployment? (y/N)`. Anything other than `y`/`Y` → `exit 0` (per A9 a zero-row dry-run is allowed to continue if the operator confirms).
7. **Deploy.** `docker compose up -d --build`. Then `docker compose ps`, `docker compose logs --tail 20 bridge`, and `docker inspect --format '{{.State.Health.Status}}' "${TABLE_PREFIX}_influx_mysql_bridge"` (expect `healthy` within 60s).

### 6.2 Wizard validation rules
The wizard validates every entered value against the same regex/range as `config.py`. Invalid values cause the wizard to re-prompt the same question — it does not write a malformed `.env`. The same regexes are duplicated in `deploy.sh` and `config.py`; both must stay in sync (test in M5).

### 6.3 Secret hygiene & backup
- Tokens and passwords are read with `read -rs`.
- The Update-mode default is shown as `[xxxx…last4]`, never plaintext.
- The script does not enable `set -x` at any point.
- `.env` is `chmod 600` immediately after writing.
- The Update-mode auto-backup writes `.env.bak.<unix-ts>` with `chmod 600` and is `.gitignore`d.

---

## 7. Milestones — plan with verification checkpoints

Each milestone is one PR. Inline `→ verify:` clauses are checkpoints during implementation; the PASS CRITERIA list is the binary gate to advance.

### M1 — Skeleton, config validation, container boots
**Build steps**
1. Create §3 layout with empty stubs → verify: `tree` matches §3 exactly, no extra files.
2. Implement `config.py` per §4.1 → verify: `python -c "from config import load_config; load_config()"` exits 2 with `config_error: TABLE_PREFIX: missing` when env is empty.
3. Implement `INFLUX_TAG_KEY` and `INFLUX_TAG_VALUES` parsing/validation → verify: empty list, malformed entry, and >64 entries each produce a distinct `config_error` line.
4. Write `Dockerfile` (incl. `HEALTHCHECK`) + `docker-compose.yml` (incl. `stop_grace_period: 15s`) + `.env.example` → verify: `docker compose build` produces no pip resolver warnings; `docker inspect <image> --format '{{.Config.Healthcheck.Test}}'` shows the heartbeat command.
5. `main.py` calls `load_config()` then exits 0 → verify: container starts and exits cleanly with full env.

**PASS CRITERIA**
1. `docker compose build` exits 0; build log shows zero pip `WARNING` lines.
2. With env unset, container exits **code 2** and stderr is exactly one line beginning `config_error: `.
3. `TABLE_PREFIX=BAD-Prefix` → exit 2, stderr `config_error: TABLE_PREFIX: regex`.
4. `INFLUX_TAG_KEY=Silo-1` → exit 2 (uppercase + dash both fail).
5. `INFLUX_TAG_VALUES=""` → exit 2 (empty); `INFLUX_TAG_VALUES="silo_1,silo_1"` → 1 entry kept after dedup, no error; `INFLUX_TAG_VALUES="bad value"` → exit 2 (space invalid).
6. `QUERY_WINDOW_SECONDS=10 POLL_INTERVAL_SECONDS=10` → exit 2 (window not ≥ 2 × interval).
7. `docker compose run --rm bridge id` shows `uid=10001`.
8. `docker inspect <image> --format '{{.Config.Healthcheck.Test}}'` shows the heartbeat-file probe; healthcheck interval is 30s.
9. `git diff --stat` for this PR touches only files in §3.

### M2 — MySQL bring-up, schema, idempotent + chunked inserts
**Build steps**
1. Implement `db.py:ensure_table` interpolating both `<TABLE_PREFIX>` and `<INFLUX_TAG_KEY>` → verify: against an empty DB, `SHOW CREATE TABLE` matches §5.2 character-for-character (whitespace-normalised).
2. Implement `db.py:insert_rows` with `INSERT IGNORE` and chunking at 1000 rows/statement → verify: inserting 5,500 synthetic rows results in exactly 6 chunked `INSERT IGNORE ... VALUES (...), (...)` statements visible in MySQL general log.
3. Wire `main.py` to call `ensure_table()` then exit 0 → verify: a second run is a no-op (no DDL traffic in MySQL general log).
4. Implement A8 fail-fast → verify: bad password exits 2 in <2 s with one JSON `error` line; unknown DB exits 2 similarly.

**PASS CRITERIA**
1. First run on empty DB creates `<pre>_ingest_data` with the §5.2 DDL. `SHOW CREATE TABLE` diff vs. canonical = ∅.
2. The dynamic tag column matches `${INFLUX_TAG_KEY}` and is `VARCHAR(64) NOT NULL`. The `UNIQUE KEY uq_point` includes it.
3. Second run produces no DDL traffic (verify via MySQL general log or `performance_schema.events_statements_history`).
4. `INSERT IGNORE` of `(t, m, f, "silo_1")` and `(t, m, f, "silo_2")` yields **two** rows; both succeed.
5. `INSERT IGNORE` of the same `(t, m, f, "silo_1")` twice yields **one** row.
6. Inserting a synthetic batch of 5,500 rows produces exactly **6 chunks** (1000+1000+1000+1000+1000+500). Total inserted ≥5,500 (or fewer iff dup keys collide). Statement count visible in `SHOW STATUS LIKE 'Com_insert%'`.
7. A connection drop **between chunks 3 and 4** produces one JSON `error` line (`event_subtype=db_transient`); rows from chunks 1–3 are committed; the next loop iteration backfills the rest after `INSERT IGNORE` skips already-committed rows.
8. Wrong password → exit 2 in under 2 s, single JSON `error` line on stdout (`event_subtype: db_init`), no traceback.
9. `MYSQL_DB=does_not_exist` → exit 2 with `Unknown database`-shaped error.
10. `TABLE_PREFIX="x;DROP TABLE y"` rejected at config load (M1 criterion 3 holds); zero SQL is sent.
11. `INFLUX_TAG_KEY="silo;DROP"` rejected at config load.

### M3 — Influx read path + dry-run + tag fan-out
**Build steps**
1. Implement `influx.py:query_window` with the §5.3 Flux including the `contains()` filter → verify: against a populated bucket the function returns rows for **exactly** the configured tag values, none outside the allowlist.
2. Implement `--dry-run` flag in `main.py` → verify: prints up to 10 row reprs, then `TOTAL_ROWS=N`, then `TAGS_SEEN=silo_1,silo_2,...` (sorted, deduplicated).
3. Add error handling per §4.3 → verify: with `INFLUX_URL=http://127.0.0.1:1` (refused), `--dry-run` prints exactly one JSON `error` line and exits 0.
4. Add value-cast and missing-tag-key guards → verify: a string-typed `_value` or a record missing the tag key is logged as `error` and skipped; the rest of the rows still emit.

**PASS CRITERIA**
1. Against a live bucket with at least 2 of the configured silos writing: `--dry-run` prints ≥1 `Row(...)` line per silo plus `TOTAL_ROWS=` in <2 s wall time.
2. Against an empty bucket: `--dry-run` prints `TOTAL_ROWS=0`, `TAGS_SEEN=`, and exits 0.
3. With `INFLUX_TAG_VALUES=silo_1,silo_2` but Influx contains `silo_1`, `silo_2`, `silo_99`: `TAGS_SEEN` lists only `silo_1,silo_2`; `silo_99` rows are absent.
4. Unreachable Influx: exactly one JSON line with `"level":"error"`, `"event":"error"`, `"event_subtype":"influx_query"`, then exit 0 — no traceback.
5. `INFLUX_MEASUREMENT='foo"; bad'` → rejected at config load; `tcpdump`/mitm test confirms zero requests reach Influx.
6. A non-numeric `_value` produces exactly one `error` line for that record; subsequent records still parse.
7. A record missing the configured tag key produces exactly one `error` line (`event_subtype: influx_parse`); subsequent records still parse.
8. Rows have `time_recorded.tzinfo is None` and equal the UTC moment of the Influx point (sample 3, diff = 0).

### M4 — End-to-end loop, resilience, healthcheck, graceful shutdown, rate-limited errors
**Build steps**
1. Implement the loop in §4.4 with `last_t` watermark, per-tag counter, signal handlers, heartbeat write, and `reset_error_rate_limit()` → verify: container started against live Influx+MySQL writes ≥1 row per silo within 30 s; `/tmp/last_poll.json` exists and updates each poll.
2. Implement `log.py` rate-limiter per §4.5 → verify: simulated 10 consecutive `db_transient` errors over 90s emit exactly **2** lines (one immediately, one after the 60s window with `suppressed_since_last≥1`).
3. Verify `HEALTHCHECK` integration → verify: `docker inspect --format '{{.State.Health.Status}}'` returns `healthy` during normal operation; freezing the process (`docker pause` for 60s) flips it to `unhealthy`; resuming returns to `healthy` within one poll cycle.
4. Verify graceful shutdown → verify: `docker compose stop bridge` produces exactly one `shutdown` log line, exit code 0, within ≤15s (matches `stop_grace_period`).
5. Inject Influx outage (firewall drop) for 30 s → verify: ≥1 `error` line in the first second, ≤1 additional line within the 30s window (rate-limited), container PID unchanged, ingestion resumes within one poll on restore.
6. Inject MySQL outage for 30 s → verify: same shape as Influx outage; rate-limited error stream.

**PASS CRITERIA**
1. Over a 5-minute live run with 3 silos writing: row count grows by approximately `3 × (300 / POLL_INTERVAL_SECONDS)` (allow ±10%). Sampling 5 random rows per silo and reading the same `_time`/`_field`/tag from Influx shows `field_value` matches to 6 decimal places.
2. `SELECT COUNT(*) - COUNT(DISTINCT time_recorded, measurement, field_name, <tag>) FROM <pre>_ingest_data` returns **0** after the run.
3. `SELECT DISTINCT <tag> FROM <pre>_ingest_data` returns exactly the set in `INFLUX_TAG_VALUES` (no extras, no missing).
4. `/tmp/last_poll.json` is written after every successful poll; its `ts` field is within `2 × POLL_INTERVAL_SECONDS` of `date -u`.
5. `docker inspect --format '{{.State.Health.Status}}' <container>` is `healthy` during normal operation.
6. `docker pause <container>` for 90s → `Health.Status` becomes `unhealthy`; `docker unpause` → returns to `healthy` within one poll cycle.
7. `docker compose stop bridge` produces exactly one `{"event":"shutdown","reason":"signal"}` log line; container exit code is **0**; total stop time ≤ 15s.
8. `SIGINT` (Ctrl-C in `docker compose up` foreground) produces the same shutdown line and exit 0.
9. 30 s Influx outage → 0 process exits, **≤2** JSON `error` lines emitted (one immediate + one rate-limit-window line if applicable), the second carrying `suppressed_since_last ≥ 1`. Ingestion resumes within `POLL_INTERVAL_SECONDS` of restore.
10. 30 s MySQL outage → same shape: ≤2 error lines, recovery within one poll.
11. After recovery, the next `inserted` event resets the rate-limiter; a subsequent unrelated error (different `event_subtype`) emits immediately, not after a 60s wait.
12. Steady-state `docker stats` shows CPU <2% and RSS <80 MiB on a 1-vCPU host.
13. `docker compose logs bridge | jq -c 'select(.ts)' | wc -l` equals total log line count.
14. `docker compose logs bridge | grep -E "$INFLUX_TOKEN|$MYSQL_PASSWORD"` returns empty.
15. `inserted` events contain a `per_tag` object whose keys equal `INFLUX_TAG_VALUES`.

### M5 — `deploy.sh` wizard with preflight probes & .env backup
**Build steps**
1. Skeleton with `set -euo pipefail` and dependency check → verify: `bash -n deploy.sh` clean; on host without docker, exits 1 with hint and creates no files.
2. Prompt loop with secret masking via `read -rs` → verify: typed token does not appear on screen; `set -x`-free.
3. Multi-prompt for `INFLUX_TAG_VALUES` → verify: invalid entry is rejected and re-prompted; empty input ends the list; final list deduplicated.
4. State-awareness branch → verify: second invocation offers Reuse/Update/Cancel; Cancel produces zero file changes (`git status` clean).
5. **`.env` backup before overwrite (Update mode)** → verify: an Update run leaves a `.env.bak.<unix-ts>` file with mode 600 in the working dir; original `.env` is updated; both files have identical mode.
6. **Preflight probes** → verify: with a wrong `INFLUX_TOKEN`, the wizard exits **3** with a one-line `curl` error, the bridge image is *not* built, no `docker compose run` is invoked. Same for an unreachable `MYSQL_HOST`.
7. Build + dry-run + confirm → verify: declining the prompt does not run `docker compose up`; accepting it does, and `docker inspect --format '{{.State.Health.Status}}'` reaches `healthy` within 60s.

**PASS CRITERIA**
1. `shellcheck deploy.sh` → zero warnings, zero errors.
2. Fresh host without docker → `deploy.sh` exits 1, no `.env` written, message links to docker docs.
3. Fresh run walks every prompt in §5.1 order, writes `.env` with mode `600` (`stat -c '%a' .env` = `600`).
4. Re-run on existing `.env` → menu shows; Cancel produces zero changes; Reuse skips to step 5; Update shows `[xxxx…last4]` defaults.
5. Tokens/passwords masked: a screen capture of an Update run shows no plaintext for `INFLUX_TOKEN` / `MYSQL_PASSWORD`.
6. Tag-values multi-prompt: entering `silo_1`, `bad value`, `silo_2`, `<empty>` results in `INFLUX_TAG_VALUES=silo_1,silo_2`; the invalid entry produced an inline rejection message.
7. Update mode produces `.env.bak.<unix-ts>` with mode 600; the file's content matches the previous `.env` byte-for-byte (`diff` = ∅).
8. Preflight probe with bad Influx token → wizard exits **3**, stderr contains the `curl` exit message, no `docker compose build` line in the wizard output.
9. Preflight probe with unreachable MySQL → wizard exits **3**, no image build attempted.
10. Successful preflight → dry-run prints ≤10 row reprs + `TOTAL_ROWS=N` + `TAGS_SEEN=...`. Declining `y` exits 0 without `docker compose up`.
11. Accepting `y` results in `docker compose ps` showing the bridge `Up`, `docker compose logs --tail 20` containing at least one `inserted` or `idle` event, and `docker inspect --format '{{.State.Health.Status}}' <container>` returning `healthy` within 60s.
12. `deploy.sh` regex blocks for `TABLE_PREFIX` / `INFLUX_TAG_KEY` / `INFLUX_TAG_VALUES` are byte-identical to `config.py`'s regexes (`grep -oE '\^.*\$'` extraction matches).

### M6 — README & operator handover
**Build steps**
1. Quickstart for Ubuntu 22.04/24.04 — exact commands a teammate runs on a clean VM → verify: a fresh teammate, given only the README, brings up a working bridge in ≤10 minutes.
2. Env var reference — copy §5.1 verbatim → verify: `comm -3 <(awk -F= '/^[A-Z_]+=/{print $1}' .env.example | sort) <(grep -oE '^\| `[A-Z_]+`' README.md | tr -d '|` ' | sort)` is empty.
3. Operations — `docker compose logs -f bridge`, log-rotation note, schema shown verbatim from §5.2, **healthcheck inspection commands** (`docker inspect --format '{{.State.Health.Status}}'`, `cat /tmp/last_poll.json` via `docker exec`).
4. Troubleshooting — six documented cases (each: **symptom → diagnostic command → fix**):
   - Bad Influx token (`401 Unauthorized`).
   - `network_mode: host` vs containerised Influx/MySQL mismatch.
   - MySQL 8.4 `caching_sha2_password` symptom (per A10).
   - Tag values misconfigured (rows missing for one silo).
   - Tag key changed between deploys (DDL conflict — see §10 reset procedure).
   - Container `Health.Status` stuck at `unhealthy` (process running but loop hung — root causes + `docker logs` hints).
5. Schema reset procedure (per A14) — exact `DROP TABLE` + restart commands.
6. Time-sync recommendation — one paragraph noting that host clock skew vs. Influx silently affects watermark/Flux range; recommend `chrony` or `systemd-timesyncd`.

**PASS CRITERIA**
1. Quickstart followed verbatim by a fresh teammate on a clean VM brings up a bridge whose `Health.Status` is `healthy` and which emits at least one `inserted` log line in ≤10 minutes.
2. Env var symmetric difference between README and `.env.example` = ∅.
3. README contains no developer-environment hostnames, IPs, tokens, or passwords (`grep -E "10\.|192\.168|127\.0\.0\.1|Bearer|password"` returns only generic placeholders).
4. Each troubleshooting case shows the **observable symptom**, the **diagnostic command**, and the **fix** — not just prose.
5. The schema reset procedure has been executed by the agent on the test stack and the resulting bridge run produces a fresh table without manual SQL surgery.
6. The healthcheck section names two specific failure shapes (process exited vs. process hung) and which `docker` command distinguishes them.

### M7 — Final acceptance
**PASS CRITERIA**
1. M1–M6 boxes all true with evidence (log excerpts, `SELECT` outputs, `docker stats` screenshot, `docker inspect` health output, `shellcheck` output, `SHOW CREATE TABLE` output) attached in the PR description.
2. `docker compose down && (edit one .env value) && docker compose up -d --build` picks up the new value with no stale state.
3. `git diff --stat main..HEAD` shows changes confined to files listed in §3 — no orphan files, no surprise edits.
4. The §0.1 `Assumptions:` notes from each milestone are consolidated into a single section at the top of the PR description.

---

## 8. Examples — wrong shape vs. right shape

| Wrong (overbuilt / leaky / vague) | Right (Karpathy-aligned) |
|---|---|
| Add a `BaseSyncEngine` ABC and `InfluxToMySQLSyncEngine` subclass for "extensibility." | One module, one `run()` function. Add abstraction the second time it's needed. |
| Use `tenacity` for retries. | `try/except mysql.connector.Error: log; return 0` inside the existing 10s loop. |
| Catch `Exception` at the top level and `pass`. | Catch `mysql.connector.Error` and `influxdb_client.rest.ApiException` specifically. |
| Wire `logging` with handlers/formatters. | `print(json.dumps(...), flush=True)` plus a 50-line rate-limiter. |
| "Verify it works" by eyeballing logs. | `SELECT COUNT(*) - COUNT(DISTINCT ...)` returns 0; sample 5 rows match Influx. Binary, runnable. |
| Slip a small `config.py` refactor into the M3 PR. | Open a separate PR. M3's diff touches only `influx.py` and `main.py`. |
| Auto-discover all tag values from Influx on startup. | Allowlist via `INFLUX_TAG_VALUES`. New silos require an explicit env update. |
| Add an HTTP `/healthz` endpoint and a tiny webserver. | A heartbeat file plus the Dockerfile `HEALTHCHECK`. No HTTP, no extra port. |
| Spin a watchdog thread that calls `os.kill` on hang. | Dockerfile `HEALTHCHECK` flips the container `unhealthy`; orchestrator decides; no in-process thread races. |
| Trap SIGTERM and call `sys.exit(0)` immediately. | Set a flag, let the current iteration finish, write final heartbeat, then exit cleanly. |
| Auto-`ALTER TABLE` to add a new tag column when `INFLUX_TAG_KEY` changes. | Fail fast on schema mismatch; document the manual `DROP TABLE` reset. |
| Add `--once`, `--verbose`, `--config-file` CLI flags. | Only `--dry-run`. That's the one §6 requires. |
| Use string-formatting to splice tag values into Flux directly. | Substitute via Python f-string after regex validation; values rendered as a Flux `[...]` literal that Influx parses. |
| Skip pre-flight probes — let the dry-run surface any issue. | Two surgical probes (`curl Influx /health`, `mysql -e 'SELECT 1'`) before the build, so failure modes are unambiguous. |

---

## 9. Things the agent must explicitly NOT do

- Introduce SQLAlchemy, Alembic, Pydantic, structlog, tenacity, APScheduler, asyncio, aiomysql, prometheus-client, or any web framework.
- Add `/healthz` HTTP endpoints, metrics endpoints, sidecars, in-process watchdog threads, or signal handlers beyond the SIGTERM/SIGINT graceful-shutdown handler in §4.4.
- Implement multi-field, multi-measurement, or auto-tag-discovery ingestion.
- Add columns "for future use." Schema changes require a new spec.
- Switch storage to TimescaleDB, Postgres, SQLite, or anything other than MySQL/MariaDB.
- Reformat or rename code that the milestone does not require.
- Cache anything across container restarts. The watermark is in-process only; the unique key is the durable guard. `/tmp/last_poll.json` is intentionally tmpfs and not persisted.
- **Issue `DROP`, `TRUNCATE`, `DELETE`, or `ALTER` against the target database. Ever.** A schema mismatch is reported via a `db_init` error and a non-zero exit; the human admin owns the reset (per A20).
- Generate Kubernetes manifests, systemd units, or Ansible roles.

---

## 10. Failure Modes Matrix

| Source | Trigger | Detected as | Log event | Action | Process state | Recovery |
|---|---|---|---|---|---|---|
| Config | Missing required var | `KeyError` in `config.py` | `config_error: VAR: missing` (stderr) | `sys.exit(2)` | exits | operator fixes `.env` |
| Config | Invalid format (regex) | regex mismatch | `config_error: VAR: regex` | `sys.exit(2)` | exits | operator fixes `.env` |
| Config | Window < 2× interval | range check | `config_error: QUERY_WINDOW_SECONDS: range` | `sys.exit(2)` | exits | operator fixes `.env` |
| MySQL init | `Access denied` (errno 1045) | `ProgrammingError` | `error event_subtype=db_init` | `sys.exit(2)` (per A8) | exits | operator fixes credential |
| MySQL init | `Unknown database` (errno 1049) | `ProgrammingError` | `error event_subtype=db_init` | `sys.exit(2)` | exits | operator creates DB |
| MySQL init | Connection refused | `OperationalError` | `error event_subtype=db_transient` | `raise TransientDBError` | exits 1, compose restarts | server returns |
| MySQL runtime | Connection lost mid-insert | `mysql.connector.Error` | `error event_subtype=db_transient` (rate-limited) | log, return rows-so-far | continues | next poll inserts; INSERT IGNORE skips dups |
| MySQL runtime | Chunk N+1 fails after N committed | same as above | same | log, return N×1000 affected | continues | next poll re-sends remaining; IGNORE skips committed |
| MySQL runtime | Duplicate key (bug or watermark slip) | not raised — `INSERT IGNORE` | — | — | continues | — |
| Influx | HTTP timeout | `urllib3.exceptions.*` | `error event_subtype=influx_query` (rate-limited) | log, return `[]` | continues | next poll re-queries |
| Influx | 401/403 | `ApiException` 4xx | `error event_subtype=influx_query` (rate-limited) | log, return `[]` | continues | operator fixes token |
| Influx record | Missing tag key | `KeyError` in mapper | `error event_subtype=influx_parse` (rate-limited) | skip record | continues | data is in Influx; later poll picks up |
| Influx record | Non-numeric `_value` | `ValueError` from `float()` | `error event_subtype=value_cast` (rate-limited) | skip record | continues | — |
| OS | SIGTERM (`docker compose stop`) | `signal.signal` handler | `shutdown reason=signal` | finish iteration, write heartbeat, exit 0 | exits 0 | operator restart |
| OS | SIGKILL | n/a (uncatchable) | — | immediate kill | exits 137 | compose restarts |
| Process | Hung loop (e.g. socket deadlock) | `HEALTHCHECK` heartbeat stale | none from process | container marked `unhealthy` | running but unhealthy | operator runs `docker compose restart bridge`; future improvement could automate via `autoheal` sidecar (out of scope) |

---

## 11. Operator Acceptance Runbook

For M6's quickstart and M7's final acceptance. Run on a clean Ubuntu 22.04/24.04 VM; everything is one command per line.

```bash
# Prereqs (one-time)
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 git jq curl

# Clone and configure
git clone <REPO_URL> influx-mysql-bridge && cd influx-mysql-bridge
./deploy.sh
# Walk the wizard. Pre-flight probes will catch a bad token or unreachable MySQL
# before the bridge image is even built. When asked for INFLUX_TAG_VALUES, enter
# your silos one by one. Approve the dry-run with `y`.

# Verify the bridge is running and healthy
docker compose ps
docker inspect --format '{{.State.Health.Status}}' "${TABLE_PREFIX}_influx_mysql_bridge"
# Expected: healthy (within 60s of starting)

docker compose logs --tail 50 bridge | jq -c .
# Expected: at least one {"event":"started",...} and one {"event":"inserted",...}

# Inspect the heartbeat directly
docker exec "${TABLE_PREFIX}_influx_mysql_bridge" cat /tmp/last_poll.json
# Expected: {"ts":"2026-...","last_t":"2026-..."} updated each poll

# Verify rows are landing
mysql -h <MYSQL_HOST> -u <MYSQL_USER> -p <MYSQL_DB> \
  -e "SELECT COUNT(*) AS n,
             COUNT(DISTINCT \`<TAG_KEY>\`) AS silos,
             MIN(time_recorded), MAX(time_recorded)
      FROM \`<TABLE_PREFIX>_ingest_data\`;"

# Verify dedup invariant
mysql -h <MYSQL_HOST> -u <MYSQL_USER> -p <MYSQL_DB> \
  -e "SELECT COUNT(*) - COUNT(DISTINCT time_recorded, measurement, field_name, \`<TAG_KEY>\`)
      AS dup_rows
      FROM \`<TABLE_PREFIX>_ingest_data\`;"
# Expected: dup_rows = 0

# Verify only configured silos appear
mysql -h <MYSQL_HOST> -u <MYSQL_USER> -p <MYSQL_DB> \
  -e "SELECT \`<TAG_KEY>\`, COUNT(*) FROM \`<TABLE_PREFIX>_ingest_data\` GROUP BY 1;"

# Resilience smoke test (~1 min downtime)
sudo iptables -I OUTPUT -p tcp --dport 8086 -j DROP   # block Influx
sleep 30 && docker compose logs --tail 20 bridge      # expect ≤2 error lines (rate-limited)
sudo iptables -D OUTPUT -p tcp --dport 8086 -j DROP   # restore
sleep 15 && docker compose logs --tail 5 bridge       # expect inserted resumed

# Liveness smoke test — process pause should mark unhealthy
docker pause "${TABLE_PREFIX}_influx_mysql_bridge"
sleep 70
docker inspect --format '{{.State.Health.Status}}' "${TABLE_PREFIX}_influx_mysql_bridge"
# Expected: unhealthy
docker unpause "${TABLE_PREFIX}_influx_mysql_bridge"
sleep 30
docker inspect --format '{{.State.Health.Status}}' "${TABLE_PREFIX}_influx_mysql_bridge"
# Expected: healthy

# Graceful shutdown test
docker compose stop bridge
docker compose logs --tail 5 bridge | jq -c .
# Expected: a final {"event":"shutdown","reason":"signal"} line; exit 0

# Schema reset (only if INFLUX_TAG_KEY changes)
docker compose down
mysql -h <MYSQL_HOST> -u <MYSQL_USER> -p <MYSQL_DB> \
  -e "DROP TABLE \`<TABLE_PREFIX>_ingest_data\`;"
docker compose up -d --build
```

The runbook is reproduced in the README.

---

## 12. Definition of Done

On a clean Ubuntu 22.04/24.04 VM, an operator runs `./deploy.sh`, answers prompts (including `INFLUX_TAG_KEY=silo` and `INFLUX_TAG_VALUES=silo_1,silo_2,silo_3`), the wizard's pre-flight probes pass, the dry-run is approved, and within 20 seconds rows for **every configured silo** are landing in MySQL. `docker inspect` reports `Health.Status: healthy` within 60s. `docker compose stop` produces exactly one `shutdown` line and exits 0. A simulated 30-minute Influx outage produces ≤30 rate-limited error lines (one per minute), and recovery is automatic. Every checkbox in §7.M1–M7 holds with attached evidence. `git log` reads as one logical change per milestone. Total Python source ≤350 lines; total bash ≤200 lines.
