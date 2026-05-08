# SPEC — InfluxDB → MySQL 8.4 Resilient Sync Bridge

**For:** an autonomous coding agent (Open Claude / Claude Code).
**Target host OS:** Ubuntu 22.04 / 24.04 LTS.
**Target stack:** InfluxDB 2.x (Flux) → MySQL 8.4 LTS, via a single Dockerised Python daemon.
**Operator workflow:** one bridge container ingests one Influx measurement and fans out across an allowlist of `_field` names. There is no tag dimension in scope; the row's `field_name` is the dimension.
**Mandate:** read §0 in full, then §1, then build §7 milestone-by-milestone. Do not advance past a milestone until every PASS CRITERION holds. Do not invent scope.

---

## 0. Operating Contract — Karpathy Guidelines (binding)

Non-negotiable.

### 0.1 Think Before Coding — Surface Assumptions
> *Don't assume. Don't hide confusion. Surface tradeoffs.*

Before each milestone, write a 3–8 line `Assumptions:` note. If a requirement admits two valid readings, **stop and ask** — do not pick silently.

### 0.2 Simplicity First
> *Minimum code that solves the problem. Nothing speculative.*

No ORM. No async. No retry library. No metrics framework. No abstractions for single-use code. Python budget ≤350 lines; bash budget ≤200 lines (overage must be surfaced, not hidden).

### 0.3 Surgical Changes
> *Touch only what you must. Every changed line should trace directly to the user's request.*

No drive-by reformats. No opportunistic dependency upgrades. PR review reads `git log -p` against this rule.

### 0.4 Goal-Driven Execution
> *Define success criteria. Loop until verified.*

Every milestone in §7 is **plan-with-checkpoints** — each step has an inline `→ verify:` clause — and ends in a numbered PASS CRITERIA list. Loop (write → run → inspect → fix) until every box is true. Do not weaken a criterion that fails; surface the blocker.

---

## 1. Assumptions Surfaced (resolved with operator)

| # | Question | Resolution |
|---|---|---|
| A1 | "Silo" semantics | A literal corn silo (domain term only). The operator's Influx schema does NOT use tags to differentiate silos; multiple `_field` names under one `_measurement` carry the values. The bridge takes an allowlist of `INFLUX_FIELDS` and ingests one row per `(measurement, field)` per poll. |
| A2 | Raw points or windowed mean | **Windowed mean** — Flux uses `aggregateWindow(every: ${POLL_INTERVAL_SECONDS}s, fn: mean, createEmpty: false)`. |
| A3 | Dedup | `UNIQUE KEY (time_recorded, measurement, field_name)` + in-process `last_t` watermark + `INSERT IGNORE`. |
| A4 | Time precision | Microsecond. Influx ns → MySQL `DATETIME(6)`. |
| A5 | Timezone | UTC, naive. README documents this. |
| A6 | Networking | Host LAN. `network_mode: host`. |
| A7 | Connection pool | `pool_size=2`. |
| A8 | Init failure policy | Fail-fast on `Access denied` / `Unknown database` (`exit 2`). Retry on connection-refused (let compose restart). |
| A9 | Dry-run with zero rows | Warn-and-proceed on operator confirmation. |
| A10 | MySQL auth plugin | `caching_sha2_password` (MySQL 8.4 default), supported by `mysql-connector-python` 9.x. |
| A11 | Stack version | MySQL 8.4 LTS confirmed. MariaDB compatibility preserved at driver level but not validated. InfluxDB 2.x. |
| A12 | Field allowlist | `INFLUX_FIELDS=wheat_level,white_corn_level,…`. Flux uses `contains(value: r["_field"], set: fields)`. New fields require env update + restart. |
| A13 | Liveness vs. exit | Heartbeat file `/tmp/last_poll.json` + Docker `HEALTHCHECK`. `restart: unless-stopped` only fires on actual exits, so the heartbeat catches hung loops. |
| A14 | Shutdown | SIGTERM is graceful — current iteration finishes, heartbeat written, exit 0 within ≤1 s. |
| A15 | Sustained-outage logs | Rate-limit consecutive same-subtype errors to one line per 60 s. First successful poll after recovery resets the limiter and emits `suppressed_since_last`. |
| A16 | Backpressure | Chunked inserts at 1000 rows/statement. |
| A17 | Schema ownership | The bridge **never** issues `DROP`, `TRUNCATE`, `DELETE`, or `ALTER`. Only `CREATE TABLE IF NOT EXISTS`, read-only `information_schema` selects, and `INSERT IGNORE`. On schema mismatch (missing required columns) it logs `db_init` and `sys.exit(2)`; reset is always an admin action. |

---

## 2. System Overview

```
                ┌──────────────────────────────────────────────────────┐
                │  deploy.sh (Ubuntu wizard)                            │
                │  ─ docker dependency check                            │
                │  ─ prompts (incl. multi-prompt INFLUX_FIELDS)         │
                │  ─ writes .env (mode 600), backs up prior in Update   │
                │  ─ pre-flight: curl Influx /health, mysql SELECT 1    │
                │  ─ build, dry-run, confirm, up                        │
                └──────────────────────────┬───────────────────────────┘
                                           │
                                           ▼
                              .env + docker-compose.yml
                                           │
                                           ▼
   ┌───────────┐     Flux/HTTP     ┌────────────────┐     SQL    ┌──────────────────┐
   │ InfluxDB  │ ◄─────────────── │  bridge (py)   │ ──────────► │  MySQL 8.4 LTS   │
   │  bucket   │   every Ns       │  app/main.py   │ INSERT      │ <pre>_ingest_*   │
   └───────────┘                  └────────────────┘ IGNORE      └──────────────────┘
                                          │
                                          ├──► /tmp/last_poll.json (heartbeat)
                                          └──► docker logs (json-file)
```

Per poll, `N` rows are inserted where `N = |INFLUX_FIELDS|`. Inserts are chunked at 1000 rows/statement.

**Out of scope:** historical backfill, multi-bucket fan-in, multi-measurement ingestion, tag-based ingestion, auto-discovery of new fields, Prometheus, web UI, alerting, schema migrations beyond `CREATE TABLE IF NOT EXISTS`, async I/O, k8s manifests.

---

## 3. Repository Layout

```
.
├── app/
│   ├── main.py            # Loop: ensure_table → query_window → insert_rows → heartbeat → sleep
│   ├── db.py              # Pool, ensure_table (verify+create), chunked INSERT IGNORE
│   ├── influx.py          # Influx client + query_window
│   ├── config.py          # Env parsing + validation; SystemExit(2) on bad input
│   ├── log.py             # JSON-line logger + 60s error rate-limit
│   ├── requirements.txt
│   └── Dockerfile
├── deploy.sh              # Wizard with preflight probes and .env backup
├── docker-compose.yml
├── .env.example
├── .env                   # generated by deploy.sh; gitignored; mode 600
├── .env.bak.<unix-ts>     # auto-backup written before any Update overwrite
├── .gitignore
└── README.md
```

Runtime artifact: `/tmp/last_poll.json` (heartbeat written by `main.py`, read by Docker `HEALTHCHECK`; not committed, not persisted).

---

## 4. Component Contracts

### 4.1 `config.py`
`load_config() -> Config` (frozen dataclass). On invalid/missing input: one stderr line `config_error: VAR: reason`, then `sys.exit(2)`.

```python
@dataclass(frozen=True)
class Config:
    table_prefix: str
    influx_url: str
    influx_token: str            # never logged
    influx_org: str
    influx_bucket: str
    influx_measurement: str
    influx_fields: tuple[str, ...]   # ordered, deduplicated allowlist
    mysql_host: str
    mysql_port: int
    mysql_user: str
    mysql_password: str          # never logged
    mysql_db: str
    poll_interval_seconds: int
    query_window_seconds: int
```

| Variable | Rule |
|---|---|
| `TABLE_PREFIX` | `^[a-z][a-z0-9_]{0,30}$` |
| `INFLUX_URL` | `^https?://[A-Za-z0-9.\-]+(:[0-9]+)?$` |
| `INFLUX_TOKEN` | length ≥ 16; never logged |
| `INFLUX_ORG`, `INFLUX_BUCKET`, `INFLUX_MEASUREMENT` | `^[A-Za-z0-9_\-./]{1,128}$` |
| `INFLUX_FIELDS` | comma-separated; each item `^[A-Za-z0-9_\-./]{1,128}$`; 1–64 entries; deduplicated preserving order |
| `MYSQL_HOST`, `MYSQL_USER`, `MYSQL_DB` | non-empty |
| `MYSQL_PORT` | int 1–65535, default 3306 |
| `MYSQL_PASSWORD` | non-empty; never logged |
| `POLL_INTERVAL_SECONDS` | int [5, 3600], default 10 |
| `QUERY_WINDOW_SECONDS` | int ≥ 2 × `POLL_INTERVAL_SECONDS`, default 20 |

### 4.2 `db.py`
- `pool = MySQLConnectionPool(pool_name="bridge", pool_size=2, …)`.
- `class TransientDBError(Exception)` — retryable.
- **The module never issues `DROP`, `TRUNCATE`, `DELETE`, or `ALTER`.** Only `CREATE TABLE IF NOT EXISTS`, `SELECT … FROM information_schema.COLUMNS`, and `INSERT IGNORE`.
- `ensure_table(cfg)` first runs `_verify_schema(cfg)` (read-only column check). If the table exists but lacks one of the required columns, log `db_init` error and `sys.exit(2)` — admin reset required. Otherwise issue the §5.2 DDL.
- On `errno ∈ {1044, 1045, 1049}` (`Access denied` / `Unknown database`) → `sys.exit(2)`.
- On `OperationalError` / connection refused → raise `TransientDBError`.
- `insert_rows(cfg, rows)` — chunked at `INSERT_CHUNK_SIZE=1000` per statement, `executemany`. On mid-chunk error: log one rate-limited line, return committed-so-far count, loop continues.
- `Row = namedtuple("Row", ["time_recorded", "measurement", "field_name", "field_value"])`. `time_recorded` is UTC-naive `datetime`.

### 4.3 `influx.py`
- `client = InfluxDBClient(url=…, token=…, org=…, enable_gzip=True, timeout=10_000)`.
- `query_window(cfg) -> list[Row]` runs the §5.3 Flux.
- Per-record mapping:
  ```python
  Row(
      time_recorded=record["_time"].astimezone(timezone.utc).replace(tzinfo=None),
      measurement=record["_measurement"],
      field_name=record["_field"],
      field_value=float(record["_value"]),
  )
  ```
- On `ApiException`, `urllib3.exceptions.*`, `KeyError`, `(ValueError, TypeError)` cast: log one rate-limited error and either skip the record (parse) or return `[]` (transport). **Never raises to caller.**

### 4.4 `main.py`
```python
HEARTBEAT_PATH = "/tmp/last_poll.json"
_terminate = False

def _on_signal(s, f): global _terminate; _terminate = True
def _write_heartbeat(last_t): ...   # best-effort, never breaks the loop
def _interruptible_sleep(seconds): ...   # wakes within ~1s of SIGTERM

def run():
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    cfg = load_config()
    db.ensure_table(cfg)                   # may sys.exit(2)
    last_t = None
    log("started", prefix=cfg.table_prefix, measurement=cfg.influx_measurement,
        fields=list(cfg.influx_fields), poll=cfg.poll_interval_seconds)
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
                log("inserted", count=n, latest=last_t.isoformat(),
                    per_field=dict(Counter(r.field_name for r in rows)))
                log_module.reset_error_rate_limit()
            else:
                log("idle", window_s=cfg.query_window_seconds)
            _write_heartbeat(last_t)
        except db.TransientDBError as e:
            log("error", level="error", event_subtype="db_transient", error_msg=str(e))
        elapsed = time.monotonic() - t0
        _interruptible_sleep(max(0.0, cfg.poll_interval_seconds - elapsed))
    log("shutdown", reason="signal")
```

CLI: `python main.py --dry-run` → one query, prints up to 10 rows, then `TOTAL_ROWS=N` and `FIELDS_SEEN=…`, then `sys.exit(0)`. No heartbeat, no signal handlers in dry-run.

### 4.5 `log.py` (≤50 lines)
JSON-line logger. Consecutive errors with the same `event_subtype` within 60 s are coalesced; the next emitted error carries `suppressed_since_last`. `reset_error_rate_limit()` clears the coalescer (called by main after `inserted`).

### 4.6 `Dockerfile`
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ .
RUN useradd -u 10001 -r bridge && chown -R bridge /app
USER bridge

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=2 \
    CMD python -c "import os,sys,time; p='/tmp/last_poll.json'; \
        sys.exit(0) if os.path.exists(p) and time.time()-os.path.getmtime(p)<30 else sys.exit(1)"

ENTRYPOINT ["python", "-u", "main.py"]
```

### 4.7 `requirements.txt` (pinned)
```
influxdb-client==1.49.0
mysql-connector-python==9.4.0
```

### 4.8 `docker-compose.yml`
```yaml
services:
  bridge:
    build:
      context: .
      dockerfile: app/Dockerfile
    container_name: ${TABLE_PREFIX}_influx_mysql_bridge
    env_file: .env
    restart: unless-stopped
    network_mode: host
    stop_grace_period: 15s
    logging: { driver: json-file, options: { max-size: "10m", max-file: "5" } }
```

---

## 5. Data Contracts

### 5.1 Environment variables

| Variable | Required | Default | Rule |
|---|---|---|---|
| `TABLE_PREFIX` | yes | — | regex |
| `INFLUX_URL` | yes | — | scheme + host[:port], no trailing `/` |
| `INFLUX_TOKEN` | yes | — | len ≥ 16; redacted |
| `INFLUX_ORG` | yes | — | regex |
| `INFLUX_BUCKET` | yes | — | regex |
| `INFLUX_MEASUREMENT` | yes | — | regex |
| `INFLUX_FIELDS` | yes | — | comma-separated, regex per item, 1–64 |
| `MYSQL_HOST` | yes | — | non-empty |
| `MYSQL_PORT` | no | `3306` | int 1–65535 |
| `MYSQL_USER` | yes | — | non-empty |
| `MYSQL_PASSWORD` | yes | — | redacted |
| `MYSQL_DB` | yes | — | non-empty |
| `POLL_INTERVAL_SECONDS` | no | `10` | int [5, 3600] |
| `QUERY_WINDOW_SECONDS` | no | `20` | int ≥ 2× poll |
| `COMPOSE_PROJECT_NAME` | auto | `${TABLE_PREFIX}` | set by deploy.sh |

### 5.2 SQL DDL (canonical)

```sql
CREATE TABLE IF NOT EXISTS `<pre>_ingest_data` (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    time_recorded   DATETIME(6)   NOT NULL,                      -- UTC, naive (A5)
    measurement     VARCHAR(255)  NOT NULL,
    field_name      VARCHAR(255)  NOT NULL,
    field_value     DOUBLE        NOT NULL,
    created_at      TIMESTAMP(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    UNIQUE KEY uq_point (time_recorded, measurement, field_name),
    KEY idx_time (time_recorded),
    KEY idx_field_time (field_name, time_recorded)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
```

### 5.3 Flux query (canonical)

```flux
fields = ["${FIELD_1}", "${FIELD_2}", ...]

from(bucket: "${INFLUX_BUCKET}")
  |> range(start: -${QUERY_WINDOW_SECONDS}s)
  |> filter(fn: (r) => r["_measurement"] == "${INFLUX_MEASUREMENT}")
  |> filter(fn: (r) => contains(value: r["_field"], set: fields))
  |> aggregateWindow(every: ${POLL_INTERVAL_SECONDS}s, fn: mean, createEmpty: false)
  |> yield(name: "last")
```

Substitution is done in Python from validated config; no operator string ever reaches Flux unvalidated.

### 5.4 Log line schema

One JSON object per line on stdout. Keys: `ts` (ISO-8601 UTC, microseconds), `level` (`info|warn|error`), `event` (snake_case), plus event-specific keys.

Canonical events:
- `started` — `{ prefix, measurement, fields, poll, window }`
- `inserted` — `{ count, latest, per_field }` (resets the error rate-limiter)
- `idle` — `{ window_s }`
- `error` — `{ event_subtype, error_msg, [error_type], [committed_so_far], [suppressed_since_last] }`
  - subtypes: `influx_query`, `influx_parse`, `db_transient`, `db_init`, `value_cast`
- `shutdown` — `{ reason: "signal" }`

`INFLUX_TOKEN` and `MYSQL_PASSWORD` are forbidden in any log line. Only unhandled exceptions get a Python traceback.

---

## 6. `deploy.sh` (Ubuntu wizard)

POSIX `#!/usr/bin/env bash`, `set -euo pipefail`. `shellcheck` clean.

### 6.1 Order
1. **Dep check** — `command -v docker` + `docker compose version`. Missing → install hint, `exit 1`.
2. **State menu** — if `.env` exists: `(1) Reuse  (2) Update  (3) Cancel`.
3. **Prompts.** Single-value prompts use `prompt_value VAR LABEL REGEX [secret]`. Comma-aware error messages (a comma in a single-value prompt yields "this field accepts ONE value only — no commas"). Tokens/passwords via `read -rs`; Update default shown as `[xxxx…last4]`.
   - Order: `TABLE_PREFIX`, `INFLUX_URL`, `INFLUX_TOKEN`, `INFLUX_ORG`, `INFLUX_BUCKET`, `INFLUX_MEASUREMENT`, then `prompt_fields` (multi), then `MYSQL_*`, `POLL_INTERVAL_SECONDS`, `QUERY_WINDOW_SECONDS`.
4. **`prompt_fields`** — multi-prompt for `INFLUX_FIELDS`. Prints a header explaining the loop, numbers each prompt (`Field #N`), shows the running list (`[collected: a, b, c]`), rejects commas with a specific message, dedups, caps at 64.
5. **Persist.** In Update mode, `cp .env .env.bak.$(date +%s)` first; then write new `.env`, `chmod 600`. `COMPOSE_PROJECT_NAME=${TABLE_PREFIX}` added.
6. **Pre-flight probes** (before build):
   - `curl -fsS --max-time 5 -H "Authorization: Token $TOKEN" "$INFLUX_URL/health"` (falls back to unauthenticated `/health` for instances that allow it). Failure → `exit 3`, no build.
   - `docker run --rm --network host mysql:8.4 mysql … -e "SELECT 1"`. Failure → `exit 3`, no build.
7. **Build + dry-run + confirm.** `docker compose build`; then `docker compose run --rm bridge --dry-run`; prompt `Proceed with deployment? (y/N)`. Anything but `y`/`Y` → `exit 0`.
8. **Deploy.** `docker compose up -d --build`; print `ps`, last 20 logs, and wait up to 60 s for `Health.Status: healthy`.

Exit codes: `0` success / cancel; `1` missing deps; `2` config validation failure; `3` pre-flight probe failure.

---

## 7. Milestones — plan with verification checkpoints

### M1 — Skeleton, config validation, container boots
**Build steps**
1. Repo layout (§3) → verify: `tree` matches.
2. `config.py` per §4.1 → verify: empty env exits 2 with `config_error: TABLE_PREFIX: missing`.
3. `INFLUX_FIELDS` parsing/validation → verify: empty / >64 / regex-failure each exit 2 distinctly.
4. `Dockerfile` (incl. `HEALTHCHECK`), `docker-compose.yml` (incl. `stop_grace_period`), `.env.example` → verify: `docker compose build` produces no pip warnings.
5. `main.py` calls `load_config()` and exits 0.

**PASS CRITERIA**
1. `docker compose build` exits 0; zero pip `WARNING` lines.
2. Env unset → exit 2, single `config_error: …` line.
3. `TABLE_PREFIX=BAD-Prefix` → exit 2 (`regex`).
4. `INFLUX_FIELDS=""` → exit 2 (`empty`); `INFLUX_FIELDS=a,a,b` → dedups to `('a', 'b')`; `INFLUX_FIELDS="bad value"` → exit 2.
5. `QUERY_WINDOW_SECONDS=10 POLL_INTERVAL_SECONDS=10` → exit 2.
6. `docker compose run --rm bridge id` → `uid=10001`.
7. `docker inspect <image> --format '{{.Config.Healthcheck.Test}}'` shows the heartbeat probe.

### M2 — MySQL bring-up, schema, idempotent + chunked inserts
**Build steps**
1. `db.py:ensure_table` (with `_verify_schema`) → verify: against an empty DB, `SHOW CREATE TABLE` matches §5.2.
2. `db.py:insert_rows` chunked at 1000 → verify: 5,500 synthetic rows produce 6 `INSERT IGNORE` statements visible in MySQL general log.
3. `main.py` calls `ensure_table()` then exits → verify: a second run is a no-op (no DDL traffic).
4. A8 fail-fast → verify: bad password exits 2 in <2 s with one JSON `error` line.

**PASS CRITERIA**
1. First run on empty DB creates `<pre>_ingest_data` exactly per §5.2.
2. Second run produces no DDL traffic.
3. `INSERT IGNORE` of `(t,m,f1)` and `(t,m,f2)` → 2 rows; same `(t,m,f1)` twice → 1 row.
4. 5,500-row batch → exactly 6 chunks (5×1000 + 1×500); count visible in `SHOW STATUS LIKE 'Com_insert%'`.
5. Connection drop between chunks 3 and 4 → one JSON `db_transient` error, rows from chunks 1–3 committed, next loop backfills (IGNORE skips committed rows).
6. Wrong password → exit 2 in <2 s, one `db_init` line.
7. `MYSQL_DB=does_not_exist` → exit 2.
8. **Existing table missing a required column → exit 2, one `db_init` line, NO `DROP`/`ALTER` issued (verify via MySQL general log).**
9. `TABLE_PREFIX="x;DROP TABLE y"` rejected at config load.

### M3 — Influx read path + dry-run + field fan-out
**Build steps**
1. `influx.py:query_window` with `contains()` filter on `_field` → verify: only configured fields appear in returned rows.
2. `--dry-run` → prints up to 10 row reprs, `TOTAL_ROWS=N`, `FIELDS_SEEN=…`.
3. Error handling per §4.3 → verify: unreachable Influx prints exactly one JSON `influx_query` error, exits 0.
4. Cast/parse guards → verify: a string `_value` or missing `_field` is logged as `error` and skipped.

**PASS CRITERIA**
1. Live bucket with ≥2 of the configured fields writing: `--dry-run` prints ≥1 row per field plus `TOTAL_ROWS=` in <2 s.
2. Empty bucket → `TOTAL_ROWS=0`, `FIELDS_SEEN=`, exit 0.
3. With `INFLUX_FIELDS=a,b` but Influx contains `a, b, c`: `FIELDS_SEEN=a,b`; `c` is absent.
4. Unreachable Influx → exactly one JSON line `event_subtype=influx_query`, exit 0.
5. `INFLUX_MEASUREMENT='foo"; bad'` rejected at config load (no request reaches Influx).
6. Non-numeric `_value` → one `value_cast` error; siblings still parse.
7. Missing `_field` in record → one `influx_parse` error; siblings still parse.
8. `time_recorded.tzinfo is None` and equals the UTC moment of the Influx point.

### M4 — End-to-end loop, resilience, healthcheck, graceful shutdown, rate-limited errors
**Build steps**
1. Loop in §4.4 with `last_t`, signals, heartbeat, `reset_error_rate_limit()` → verify: container writes ≥1 row per field within 30 s; `/tmp/last_poll.json` updates each poll.
2. `log.py` rate-limiter → verify: 10 consecutive `db_transient` errors over 90 s emit exactly 2 lines (one immediate + one window-end with `suppressed_since_last≥1`).
3. HEALTHCHECK → `docker pause` flips `Health.Status` to `unhealthy`; `unpause` → `healthy` within one poll.
4. Graceful shutdown → `docker compose stop` produces one `shutdown` line, exit 0, ≤15 s.
5. 30 s Influx outage → ≤2 error lines, recovery within one poll.
6. 30 s MySQL outage → same.

**PASS CRITERIA**
1. 5-minute live run with 3 fields: row count grows by ≈ `3 × (300 / POLL_INTERVAL_SECONDS)` (±10 %); 5 sample rows match Influx to 6 decimals.
2. `SELECT COUNT(*) - COUNT(DISTINCT time_recorded, measurement, field_name) = 0`.
3. `SELECT DISTINCT field_name` = `INFLUX_FIELDS` exactly.
4. `/tmp/last_poll.json` ts within `2 × POLL_INTERVAL_SECONDS` of `date -u`.
5. `Health.Status: healthy` during normal op.
6. `docker pause` for 90 s → `unhealthy`; `unpause` → `healthy` in one poll.
7. `docker compose stop` → exactly one `{"event":"shutdown","reason":"signal"}`, exit 0, ≤15 s.
8. SIGINT → same shape.
9. 30 s Influx outage → 0 process exits, ≤2 error lines, `suppressed_since_last ≥ 1` on the second.
10. 30 s MySQL outage → same.
11. Recovery resets the limiter; a different `event_subtype` after recovery emits immediately.
12. Steady state: CPU <2 %, RSS <80 MiB.
13. Every log line is valid JSON.
14. `grep` for token/password in logs returns empty.
15. `inserted.per_field` keys = `INFLUX_FIELDS`.

### M5 — `deploy.sh` wizard with preflight + .env backup
**Build steps**
1. Skeleton + dep check → verify: no-docker host exits 1.
2. Single-value prompts with comma/space-aware error messages → verify: typing a comma into `INFLUX_MEASUREMENT` yields "ONE value only — no commas".
3. `prompt_fields` multi-loop with header, numbered prompts, running-list display, dedup, comma rejection → verify: typing `a,b,c` at field #1 yields "enter ONE field at a time"; typing `a` then `a` yields "already added"; entering `a` then `<Enter>` finalises with "1 field(s)".
4. State branch → verify: Cancel produces `git status` clean.
5. `.env` backup before overwrite → verify: backup file mode 600, byte-identical to prior `.env`.
6. Pre-flight probes → verify: bad token → exit 3, no `docker compose build`; unreachable MySQL → same.
7. Build + dry-run + confirm → verify: declining the prompt does not run `docker compose up`.

**PASS CRITERIA**
1. `shellcheck deploy.sh` zero warnings.
2. No-docker host → exit 1, no `.env` written.
3. Fresh run writes `.env` mode 600.
4. Re-run offers Reuse/Update/Cancel; Cancel = no changes; Update shows `[xxxx…last4]` defaults.
5. Tokens masked.
6. Multi-prompt: `a,b`, ` a`, `a`, `a`, `<Enter>` produces `INFLUX_FIELDS=a` with three rejection messages.
7. Update `.env.bak.<unix-ts>` mode 600, `diff` to prior = ∅.
8. Bad Influx token → exit 3, no build.
9. Unreachable MySQL → exit 3, no build.
10. Successful preflight + decline `y` → no `docker compose up`.
11. Accept `y` → bridge `Up`, `Health.Status: healthy` within 60 s.
12. Regex blocks in deploy.sh and config.py represent the same character set (M5 cross-check).

### M6 — README & operator handover
PASS CRITERIA: quickstart works in ≤10 minutes on a clean VM; README env table = `.env.example` set; six troubleshooting cases each show symptom → diagnostic command → fix; reset procedure documented.

### M7 — Final acceptance
PASS CRITERIA: M1–M6 boxes ticked with evidence; `docker compose down && (edit one .env value) && docker compose up -d --build` picks up the new value with no stale state; `git diff --stat main..HEAD` confined to §3 files; `Assumptions:` notes consolidated in PR description.

---

## 8. Examples — wrong shape vs. right shape

| Wrong | Right |
|---|---|
| `BaseSyncEngine` ABC + subclass for "extensibility." | One `run()` function. Add abstraction the second time it's needed. |
| `tenacity` for retries. | `try/except mysql.connector.Error: log; return 0` inside the existing loop. |
| Catch `Exception` and `pass`. | Catch `mysql.connector.Error` / `ApiException` specifically. |
| Wire `logging` with handlers/formatters. | `print(json.dumps(...), flush=True)` plus a 50-line rate-limiter. |
| Eyeball logs for verification. | `SELECT COUNT(*) - COUNT(DISTINCT …) = 0`; sample matches. |
| Slip a `config.py` refactor into M3. | Separate PR. M3 touches only `influx.py` and `main.py`. |
| Auto-discover all `_field` names from Influx. | Allowlist via `INFLUX_FIELDS`; new fields require an env update. |
| HTTP `/healthz` endpoint. | Heartbeat file + Dockerfile `HEALTHCHECK`. |
| In-process watchdog thread. | Dockerfile `HEALTHCHECK` flips `unhealthy`; orchestrator decides. |
| Trap SIGTERM and `sys.exit(0)` immediately. | Set a flag; finish iteration; write final heartbeat; exit cleanly. |
| Auto-`ALTER TABLE` to add a missing column. | Fail-fast on schema mismatch; admin reset only. |
| `--once`, `--verbose`, `--config-file` CLI. | Only `--dry-run`. |
| Skip pre-flight probes. | Two surgical probes (Influx `/health`, `mysql SELECT 1`) before build. |

---

## 9. Things the agent must explicitly NOT do

- Introduce SQLAlchemy, Alembic, Pydantic, structlog, tenacity, APScheduler, asyncio, aiomysql, prometheus-client, or any web framework.
- Add `/healthz`, metrics endpoints, sidecars, in-process watchdog threads, or signal handlers beyond the SIGTERM/SIGINT graceful-shutdown handler.
- Implement multi-measurement, tag-based, or auto-discovery ingestion.
- Add columns "for future use." Schema changes require a new spec.
- Switch storage to TimescaleDB, Postgres, SQLite, etc.
- Reformat or rename code that the milestone does not require.
- Cache anything across container restarts. The watermark is in-process; the unique key is durable; the heartbeat file is tmpfs.
- **Issue `DROP`, `TRUNCATE`, `DELETE`, or `ALTER` against the target database. Ever.** Schema mismatch → `db_init` error + `sys.exit(2)`. The admin owns reset.
- Generate Kubernetes manifests, systemd units, or Ansible roles.

---

## 10. Failure Modes Matrix

| Source | Trigger | Detected as | Log event | Action | Process | Recovery |
|---|---|---|---|---|---|---|
| Config | Missing var | `KeyError` | `config_error: VAR: missing` | exit 2 | exits | operator fixes `.env` |
| Config | Invalid format | regex | `config_error: VAR: regex` | exit 2 | exits | operator fixes `.env` |
| Config | Window < 2× interval | range | `config_error: QUERY_WINDOW_SECONDS: range` | exit 2 | exits | operator fixes `.env` |
| MySQL init | `Access denied` (1045) | `ProgrammingError` | `db_init` | exit 2 | exits | operator fixes credential |
| MySQL init | `Unknown database` (1049) | `ProgrammingError` | `db_init` | exit 2 | exits | operator creates DB |
| MySQL init | Connection refused | `OperationalError` | `db_transient` | `TransientDBError` | exit 1, restarts | server returns |
| MySQL init | Existing table missing required column | column-set diff | `db_init` (lists missing cols) | exit 2 | exits | admin DROPs and restarts (README §Reset) |
| MySQL runtime | Connection lost mid-insert | `mysql.connector.Error` | `db_transient` (rate-limited) | log, return committed count | continues | next poll backfills via IGNORE |
| MySQL runtime | Chunk N+1 fails after N committed | same | same | log, return N×1000 | continues | next poll re-sends remaining |
| MySQL runtime | Duplicate key | not raised — `INSERT IGNORE` | — | — | continues | — |
| Influx | HTTP timeout | `urllib3` exc | `influx_query` (rate-limited) | log, return `[]` | continues | next poll |
| Influx | 401/403 | `ApiException` | `influx_query` (rate-limited) | log, return `[]` | continues | operator fixes token |
| Influx record | Missing `_field` | `KeyError` | `influx_parse` (rate-limited) | skip record | continues | data is in Influx; later poll picks up |
| Influx record | Non-numeric `_value` | `ValueError` | `value_cast` (rate-limited) | skip record | continues | — |
| OS | SIGTERM | handler | `shutdown reason=signal` | finish iteration, exit 0 | exits 0 | operator restart |
| OS | SIGKILL | uncatchable | — | immediate kill | exit 137 | compose restarts |
| Process | Hung loop | heartbeat stale | none from process | container `unhealthy` | running but unhealthy | operator `docker compose restart bridge` |

---

## 11. Operator Acceptance Runbook

```bash
# Prereqs (one-time)
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 git jq curl

# Configure and deploy
git clone <REPO_URL> silo-data && cd silo-data
./deploy.sh
# Walk the wizard. INFLUX_FIELDS is a multi-prompt: enter ONE field per line,
# blank line to finish. Pre-flight probes catch bad token/host before build.

# Verify
docker compose ps
docker inspect --format '{{.State.Health.Status}}' "${TABLE_PREFIX}_influx_mysql_bridge"
docker compose logs --tail 50 bridge | jq -c .          # expect started + inserted
docker exec "${TABLE_PREFIX}_influx_mysql_bridge" cat /tmp/last_poll.json

# Row landing
mysql -h <H> -u <U> -p <DB> -e "
  SELECT COUNT(*) AS n,
         COUNT(DISTINCT field_name) AS fields,
         MIN(time_recorded), MAX(time_recorded)
  FROM \`${TABLE_PREFIX}_ingest_data\`;"

# Dedup invariant
mysql -h <H> -u <U> -p <DB> -e "
  SELECT COUNT(*) - COUNT(DISTINCT time_recorded, measurement, field_name)
  AS dup_rows
  FROM \`${TABLE_PREFIX}_ingest_data\`;"     # expect 0

# Per-field counts
mysql -h <H> -u <U> -p <DB> -e "
  SELECT field_name, COUNT(*)
  FROM \`${TABLE_PREFIX}_ingest_data\` GROUP BY 1;"

# Resilience smoke (~1 min Influx outage)
sudo iptables -I OUTPUT -p tcp --dport 8086 -j DROP
sleep 30 && docker compose logs --tail 20 bridge        # ≤2 error lines
sudo iptables -D OUTPUT -p tcp --dport 8086 -j DROP

# Liveness smoke
docker pause "${TABLE_PREFIX}_influx_mysql_bridge" && sleep 70
docker inspect --format '{{.State.Health.Status}}' "${TABLE_PREFIX}_influx_mysql_bridge"   # unhealthy
docker unpause "${TABLE_PREFIX}_influx_mysql_bridge"

# Graceful shutdown
docker compose stop bridge
docker compose logs --tail 5 bridge | jq -c .            # final shutdown line, exit 0

# Reset (admin only — bridge will not perform this)
docker compose down
mysql -h <H> -u <U> -p <DB> \
  -e "DROP TABLE \`${TABLE_PREFIX}_ingest_data\`;"
docker compose up -d --build
```

---

## 12. Definition of Done

On a clean Ubuntu 22.04/24.04 VM, an operator runs `./deploy.sh`, answers prompts (including `INFLUX_FIELDS=wheat_level,white_corn_level,yellow_corn_level`), pre-flight probes pass, dry-run is approved, and within 20 seconds rows for **every configured field** are landing in MySQL. `Health.Status` reaches `healthy` within 60 s. `docker compose stop` emits one `shutdown` line and exits 0. A 30-minute simulated outage produces ≤30 rate-limited error lines (one per minute), and recovery is automatic. All §7 PASS CRITERIA have evidence attached. `git log` reads as one logical change per milestone. Python ≤350 lines / bash ≤200 (overage surfaced in VERIFICATION.md, not silently absorbed).
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             