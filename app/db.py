"""Connection helpers shared by ingest.py and dashboard.py."""

import os
import time
from contextlib import contextmanager

import psycopg2
import psycopg2.extras
import psycopg2.pool

DB_PARAMS = dict(
    host=os.environ.get("YSQL_HOST", "localhost"),
    port=int(os.environ.get("YSQL_PORT", "5433")),
    user=os.environ.get("YSQL_USER", "yugabyte"),
    dbname=os.environ.get("YSQL_DB", "mission_control"),
)

_pool = None


def get_pool():
    global _pool
    if _pool is None:
        _pool = psycopg2.pool.ThreadedConnectionPool(1, 4, **DB_PARAMS)
    return _pool


@contextmanager
def connection():
    pool = get_pool()
    conn = pool.getconn()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        pool.putconn(conn)


def query(sql, params=None):
    """Run a query, return (rows as list of dicts, elapsed milliseconds)."""
    with connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            start = time.monotonic()
            cur.execute(sql, params)
            rows = cur.fetchall()
            elapsed_ms = (time.monotonic() - start) * 1000
    return [dict(r) for r in rows], elapsed_ms


def execute(sql, params=None):
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
