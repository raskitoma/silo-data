"""MySQL pool + ensure_table + chunked INSERT IGNORE. Per spec §4.2.

This module NEVER issues DROP, TRUNCATE, DELETE, or ALTER. It only:
  - CREATE TABLE IF NOT EXISTS
  - SELECT (against information_schema, for schema verification)
  - INSERT IGNORE

If the existing table is missing required columns, the bridge fails fast
(sys.exit 2) and asks the admin to handle the reset manually.
"""
import sys
from collections import namedtuple

import mysql.connector
from mysql.connector import errorcode
from mysql.connector.errors import OperationalError, ProgrammingError
from mysql.connector.pooling import MySQLConnectionPool

from config import Config
from log import log


INSERT_CHUNK_SIZE = 1000

Row = namedtuple(
    "Row",
    ["time_recorded", "measurement", "field_name", "field_value"],
)


class TransientDBError(Exception):
    """Retryable DB error. The loop logs and continues; init code lets compose restart."""


_pool: MySQLConnectionPool | None = None


def _ensure_pool(cfg: Config) -> MySQLConnectionPool:
    global _pool
    if _pool is None:
        _pool = MySQLConnectionPool(
            pool_name="bridge",
            pool_size=2,
            host=cfg.mysql_host,
            port=cfg.mysql_port,
            user=cfg.mysql_user,
            password=cfg.mysql_password,
            database=cfg.mysql_db,
            autocommit=True,
            connection_timeout=10,
            charset="utf8mb4",
            collation="utf8mb4_general_ci",
        )
    return _pool


def _is_fatal_init_error(e: mysql.connector.Error) -> bool:
    fatal = {
        errorcode.ER_DBACCESS_DENIED_ERROR,  # 1044
        errorcode.ER_ACCESS_DENIED_ERROR,    # 1045
        errorcode.ER_BAD_DB_ERROR,           # 1049
    }
    return getattr(e, "errno", None) in fatal


def _table_name(cfg: Config) -> str:
    # Regex-validated upstream. Safe to interpolate.
    return f"{cfg.table_prefix}_ingest_data"


def _build_create_ddl(cfg: Config) -> str:
    table = _table_name(cfg)
    return (
        f"CREATE TABLE IF NOT EXISTS `{table}` (\n"
        f"    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,\n"
        f"    time_recorded   DATETIME(6)   NOT NULL,\n"
        f"    measurement     VARCHAR(255)  NOT NULL,\n"
        f"    field_name      VARCHAR(255)  NOT NULL,\n"
        f"    field_value     DOUBLE        NOT NULL,\n"
        f"    created_at      TIMESTAMP(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),\n"
        f"    UNIQUE KEY uq_point (time_recorded, measurement, field_name),\n"
        f"    KEY idx_time (time_recorded),\n"
        f"    KEY idx_field_time (field_name, time_recorded)\n"
        f") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci"
    )


# Columns the bridge requires to be present, in any order. The table may carry
# extra admin-added columns without conflict; the bridge never SELECTs * or
# INSERTs into them.
_REQUIRED_COLUMNS = {
    "id", "time_recorded", "measurement", "field_name", "field_value", "created_at",
}


def _verify_schema(cfg: Config) -> None:
    """Verify the existing table has the required columns. NEVER drops/alters.

    Fails fast with sys.exit(2) if a required column is missing. The admin
    must DROP the table manually (see README §Reset).
    """
    pool = _ensure_pool(cfg)
    table = _table_name(cfg)
    try:
        with pool.get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT COLUMN_NAME FROM information_schema.COLUMNS "
                    "WHERE TABLE_SCHEMA = %s AND TABLE_NAME = %s",
                    (cfg.mysql_db, table),
                )
                cols = {row[0] for row in cur.fetchall()}
    except (ProgrammingError, OperationalError) as e:
        # Likely a transient/auth issue — let the caller handle it.
        raise TransientDBError(f"schema verify failed: {e}") from e

    if not cols:
        return  # Table doesn't exist; CREATE TABLE IF NOT EXISTS will handle it.

    missing = _REQUIRED_COLUMNS - cols
    if missing:
        log("error", level="error", event_subtype="db_init",
            error_msg=f"existing table `{table}` is missing columns: "
                      f"{sorted(missing)}. Admin reset required (see README).")
        sys.exit(2)


def ensure_table(cfg: Config) -> None:
    """Create the ingest table if missing; verify schema if it exists.

    Fail-fast on auth/db-not-found errors. Raise TransientDBError on
    connection-level problems so main.py can let compose restart.
    """
    try:
        _verify_schema(cfg)  # may sys.exit(2) on schema mismatch
        pool = _ensure_pool(cfg)
        with pool.get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(_build_create_ddl(cfg))
    except ProgrammingError as e:
        if _is_fatal_init_error(e):
            log("error", level="error", event_subtype="db_init",
                error_msg=str(e), errno=getattr(e, "errno", None))
            sys.exit(2)
        raise TransientDBError(str(e)) from e
    except OperationalError as e:
        raise TransientDBError(str(e)) from e


def _insert_chunk(cfg: Config, chunk: list[Row]) -> int:
    table = _table_name(cfg)
    sql = (
        f"INSERT IGNORE INTO `{table}` "
        f"(time_recorded, measurement, field_name, field_value) "
        f"VALUES (%s, %s, %s, %s)"
    )
    pool = _ensure_pool(cfg)
    with pool.get_connection() as conn:
        with conn.cursor() as cur:
            cur.executemany(
                sql,
                [
                    (r.time_recorded, r.measurement, r.field_name, r.field_value)
                    for r in chunk
                ],
            )
            return cur.rowcount or 0


def insert_rows(cfg: Config, rows: list[Row]) -> int:
    """Chunk-insert rows. Return total affected.

    On mid-chunk error, return the count from chunks already committed and
    log one rate-limited error line; the loop continues. INSERT IGNORE means
    the next poll's overlap window safely re-sends any uncommitted rows.
    """
    if not rows:
        return 0
    total = 0
    for i in range(0, len(rows), INSERT_CHUNK_SIZE):
        chunk = rows[i: i + INSERT_CHUNK_SIZE]
        try:
            total += _insert_chunk(cfg, chunk)
        except mysql.connector.Error as e:
            log("error", level="error", event_subtype="db_transient",
                error_msg=str(e), committed_so_far=total)
            return total
    return total
