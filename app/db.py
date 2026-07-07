"""Connection helpers shared by ingest.py and the Streamlit app."""

import os
import time
from contextlib import contextmanager

import psycopg2
import psycopg2.extras
import psycopg2.pool
from psycopg2.pool import PoolError

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
        # Streamlit may run overlapping reruns (autorefresh + slow seq scans +
        # multiple tabs). Keep a little headroom; connections are still short-lived.
        _pool = psycopg2.pool.ThreadedConnectionPool(1, 8, **DB_PARAMS)
    return _pool


@contextmanager
def connection():
    """Pooled connection, always returned in ``finally``.

    The old try/except-only pattern leaked when Streamlit interrupted a rerun
    mid-query (autorefresh firing again while the demo seq scan was still
    running). ``BaseException`` + ``finally`` covers that path.
    """
    pool = get_pool()
    conn = pool.getconn()
    discard = False
    try:
        yield conn
        if not conn.closed:
            conn.commit()
    except BaseException:
        if not conn.closed:
            try:
                conn.rollback()
            except Exception:
                discard = True
        raise
    finally:
        # Cleanup only. No return/raise in here: a return inside finally
        # silently discards an in-flight exception, which turned a plain
        # "database is in recovery" error into an UnboundLocalError upstream.
        if not conn.closed:
            try:
                pool.putconn(conn, close=discard)
            except Exception:
                try:
                    conn.close()
                except Exception:
                    pass


def query(sql, params=None, _retried=False):
    """Run a query, return (rows as list of dicts, elapsed milliseconds).

    Retries once on connection-level failures so one stale connection
    (cluster hiccup, node restart) doesn't blank a dashboard panel.
    """
    try:
        with connection() as conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                start = time.monotonic()
                cur.execute(sql, params)
                rows = cur.fetchall()
                elapsed_ms = (time.monotonic() - start) * 1000
        return [dict(r) for r in rows], elapsed_ms
    except (psycopg2.OperationalError, psycopg2.InterfaceError,
            psycopg2.InternalError, PoolError):
        if _retried:
            raise
        time.sleep(0.05)
        return query(sql, params, _retried=True)


def execute(sql, params=None):
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
