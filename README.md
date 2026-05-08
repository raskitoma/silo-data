# silo-data — InfluxDB → MySQL Bridge

A small Dockerised Python daemon that polls an InfluxDB 2.x bucket every 10 seconds, fans out across the configured silo tag values, and writes the per-window mean of one `(measurement, field)` pair into a MySQL/MariaDB table — one row per silo per poll.

Operator-confirmed environment: **Ubuntu 22.04/24.04 LTS** host, **MySQL 8.4 LTS** target, **InfluxDB 2.x** source, **host LAN networking** (no docker-network indirection).

## Important: schema ownership

The bridge **only ever** issues these statements against the target database:

- `CREATE TABLE IF NOT EXISTS …` (once, on startup, idempotent)
- `SELECT … FROM information_schema.COLUMNS …` (schema verification on startup)
- `INSERT IGNORE INTO …` (the data writes)

The bridge **never** issues `DROP`, `TRUNCATE`, `DELETE`, or `ALTER`. If the existing table's schema does not match the configured `INFLUX_TAG_KEY` (because an admin changed the tag key between deploys), the bridge fails fast with a clear error and refuses to start. Reset is performed manually by the database admin (see [Reset](#reset)).

## Quickstart

On a clean Ubuntu 22.04 / 24.04 host with InfluxDB and MySQL already reachable on the LAN:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 git jq curl
git clone <REPO_URL> silo-data && cd silo-data
./deploy.sh
```

The wizard prompts for every value, validates each against the same regex used by `app/config.py`, runs pre-flight `curl` and `mysql` probes, builds the image, runs a dry-run query, asks for confirmation, then brings the bridge up.

After a successful start:

```bash
docker compose ps
docker compose logs -f bridge | jq -c .
docker inspect --format '{{.State.Health.Status}}' "${TABLE_PREFIX}_influx_mysql_bridge"
docker exec "${TABLE_PREFIX}_influx_mysql_bridge" cat /tmp/last_poll.json
```

## Environment variables

| Variable | Required | Default | Notes |
|---|---|---|---|
| `TABLE_PREFIX` | yes | — | DDL identifier prefix; regex `^[a-z][a-z0-9_]{0,30}$` |
| `INFLUX_URL` | yes | — | `https?://host[:port]`, no trailing `/` |
| `INFLUX_TOKEN` | yes | — | length ≥ 16; redacted in logs |
| `INFLUX_ORG` | yes | — | |
| `INFLUX_BUCKET` | yes | — | |
| `INFLUX_MEASUREMENT` | yes | — | |
| `INFLUX_FIELD` | yes | — | single field — multi-field is out of scope |
| `INFLUX_TAG_KEY` | yes | — | regex `^[a-z][a-z0-9_]{0,30}$`; also the MySQL column name |
| `INFLUX_TAG_VALUES` | yes | — | comma-separated allowlist, 1–64 entries |
| `MYSQL_HOST` | yes | — | |
| `MYSQL_PORT` | no | `3306` | |
| `MYSQL_USER` | yes | — | |
| `MYSQL_PASSWORD` | yes | — | redacted in logs |
| `MYSQL_DB` | yes | — | |
| `POLL_INTERVAL_SECONDS` | no | `10` | int [5, 3600] |
| `QUERY_WINDOW_SECONDS` | no | `20` | int ≥ 2 × `POLL_INTERVAL_SECONDS` |
| `COMPOSE_PROJECT_NAME` | auto | `${TABLE_PREFIX}` | set by `deploy.sh` |

`INFLUX_TAG_VALUES` is an explicit allowlist. New silos require an env update + restart — the bridge does not auto-discover.

## Schema

The bridge creates this table on first start (`<pre>` is `${TABLE_PREFIX}`, `<tag>` is `${INFLUX_TAG_KEY}`):

```sql
CREATE TABLE IF NOT EXISTS `<pre>_ingest_data` (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    time_recorded   DATETIME(6)   NOT NULL,
    measurement     VARCHAR(255)  NOT NULL,
    field_name      VARCHAR(255)  NOT NULL,
    field_value     DOUBLE        NOT NULL,
    `<tag>`         VARCHAR(64)   NOT NULL,
    created_at      TIMESTAMP(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    UNIQUE KEY uq_point (time_recorded, measurement, field_name, `<tag>`),
    KEY idx_time (time_recorded),
    KEY idx_tag_time (`<tag>`, time_recorded)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
```

`time_recorded` is **UTC, timezone-naive** — Influx returns UTC, MySQL `DATETIME(6)` is naive, downstream consumers should not reinterpret. Influx nanoseconds are truncated to MySQL microseconds.

## Operations

```bash
# Stream logs (one JSON object per line)
docker compose logs -f bridge | jq -c .

# Health
docker inspect --format '{{.State.Health.Status}}' "${TABLE_PREFIX}_influx_mysql_bridge"
docker exec "${TABLE_PREFIX}_influx_mysql_bridge" cat /tmp/last_poll.json

# Restart (compose handles graceful SIGTERM, ≤15s)
docker compose restart bridge

# Update env values
./deploy.sh   # choose (2) Update; previous .env is auto-backed up to .env.bak.<unix-ts>

# Stop
docker compose stop bridge

# Tear down (bridge container only — the MySQL data is yours)
docker compose down
```

Logs use the json-file driver with rotation at 10 MB × 5 files.

### Liveness vs. exit detection

| Failure shape | Detection | Recovery |
|---|---|---|
| Process exited (uncaught exception, SIGKILL, OOM) | container state `exited` | `restart: unless-stopped` brings it back |
| Process running but loop hung | `Health.Status: unhealthy` (heartbeat file stale) | `docker compose restart bridge` |

The healthcheck reads `/tmp/last_poll.json`; if its mtime is older than 30 s the container flips to `unhealthy`.

## Reset

The bridge will not modify or drop existing tables. If `INFLUX_TAG_KEY` changes between deploys (e.g. you switch from `silo` to `location`), the existing table's tag column will not match — the bridge logs a `db_init` error and exits 2 instead of starting.

Manual reset, performed by the database admin:

```bash
docker compose down

mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p "$MYSQL_DB" \
  -e "DROP TABLE \`${TABLE_PREFIX}_ingest_data\`;"

docker compose up -d --build
```

This is intentionally a manual step. The source of truth lives in Influx; recreating the MySQL mirror is cheap, but destroying historical aggregates without an admin in the loop is not.

## Troubleshooting

**Symptom:** Pre-flight Influx probe exits with code 3.
*Diagnose:* `curl -v "$INFLUX_URL/health"`.
*Fix:* check `INFLUX_URL` (no trailing `/`), token validity, and that the host can reach the Influx port.

**Symptom:** Pre-flight MySQL probe exits with code 3.
*Diagnose:* `mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p`.
*Fix:* check credentials and that the bridge host can reach the MySQL port.

**Symptom:** Bridge exits 2 immediately on start; logs show `event_subtype=db_init` with `errno=1045` (`Access denied`).
*Diagnose:* MySQL 8.4 defaults to `caching_sha2_password`; the connector supports it but the user must be created with a compatible plugin.
*Fix:* `ALTER USER '<user>'@'%' IDENTIFIED WITH caching_sha2_password BY '<pass>';` from a privileged session.

**Symptom:** `event_subtype=db_init` log line says `existing table … has no such column` for your `INFLUX_TAG_KEY`.
*Diagnose:* `INFLUX_TAG_KEY` was changed between deploys; the existing table has the old tag column.
*Fix:* see [Reset](#reset). The bridge will never `ALTER` a live table.

**Symptom:** One silo never appears in MySQL but does appear in Influx.
*Diagnose:* `SELECT DISTINCT \`<tag>\` FROM \`<pre>_ingest_data\`;` — if the silo is missing, check `INFLUX_TAG_VALUES`.
*Fix:* update the env, run `./deploy.sh` → `(2) Update` → confirm; the bridge restarts and picks up the new allowlist.

**Symptom:** `Health.Status: unhealthy` while the container is `Up`.
*Diagnose:* `docker compose logs --tail 50 bridge` and `docker exec … cat /tmp/last_poll.json` — if the heartbeat is stale and there are no recent `error` lines, the loop is hung.
*Fix:* `docker compose restart bridge`. Capture the logs first if you want to file an issue.

**Symptom:** Many `error` lines suddenly stop, then resume after recovery.
*Cause:* That's the rate-limiter. Consecutive same-subtype errors within 60 s are coalesced; the next emitted line carries `suppressed_since_last`. A successful `inserted` event resets the limiter.

## Time sync

Both the watermark filter and the Flux `range(start: -Ns)` rely on the host clock matching the Influx server. Skew silently affects what gets ingested. Run `chrony` or `systemd-timesyncd` and verify with `chronyc tracking` or `timedatectl status`.

## Layout

```
.
├── app/
│   ├── main.py            # Loop (signal-safe), heartbeat, dry-run
│   ├── db.py              # Pool, ensure_table, schema verify, chunked INSERT IGNORE
│   ├── influx.py          # Flux query + Row mapping
│   ├── config.py          # Env validation; SystemExit(2) on bad input
│   ├── log.py             # JSON-line logger + 60s error rate-limit
│   ├── requirements.txt
│   └── Dockerfile
├── deploy.sh              # Wizard with preflight probes and .env backup
├── docker-compose.yml
├── .env.example
├── README.md
├── SPEC.md                # Full specification (binding)
└── VERIFICATION.md        # M2–M4 PASS CRITERIA the operator must run on the live stack
```

## License

Internal — easyfoods.
