"""Satellite telemetry generator for the Mission Control demo.

Positions are real: orbital elements (TLEs) for ~500 actual satellites are
propagated locally with SGP4. The TLE API is only contacted with --refresh-tle;
the vendored snapshot in tle_snapshot.json makes everything work offline.

Modes:
  --backfill        bulk-load historical telemetry via COPY (run once by `make setup`)
  (default)         live mode: insert readings at --rate per second, print inserts/sec

Environment: YSQL_HOST / YSQL_PORT / YSQL_USER / YSQL_DB (see db.py).
"""

import argparse
import io
import json
import math
import os
import random
import sys
import time
from datetime import datetime, timedelta, timezone

import psycopg2.extras
from sgp4.api import Satrec, jday

from db import connection

HERE = os.path.dirname(os.path.abspath(__file__))
TLE_SNAPSHOT = os.path.join(HERE, "tle_snapshot.json")
TLE_API = "https://tle.ivanstanojevic.me/api/tle/"
EARTH_RADIUS_KM = 6371.0
ISS_NORAD_ID = 25544


# ── TLE loading ────────────────────────────────────────────────────────────────

def load_satellites(refresh=False):
    """Return [{satelliteId, name, line1, line2, satrec}]. Snapshot-first."""
    sats = None
    if refresh:
        sats = fetch_tles_from_api()
        if sats:
            with open(TLE_SNAPSHOT, "w") as f:
                json.dump({"fetched_at": datetime.now(timezone.utc).isoformat(),
                           "source": TLE_API, "count": len(sats),
                           "satellites": sats}, f, indent=1)
            print(f"refreshed snapshot: {len(sats)} satellites")
    if sats is None:
        with open(TLE_SNAPSHOT) as f:
            sats = json.load(f)["satellites"]
    for s in sats:
        s["satrec"] = Satrec.twoline2rv(s["line1"], s["line2"])
    return sats


def fetch_tles_from_api(pages=5, page_size=100):
    """Best-effort live TLE fetch. Returns None on any failure; never load-bearing."""
    try:
        import requests
        sats, seen = [], set()
        for page in range(1, pages + 1):
            resp = requests.get(TLE_API, timeout=5,
                                params={"page-size": page_size, "page": page},
                                headers={"Accept": "application/json"})
            resp.raise_for_status()
            for m in resp.json().get("member", []):
                if m["satelliteId"] not in seen:
                    seen.add(m["satelliteId"])
                    sats.append({"satelliteId": m["satelliteId"], "name": m["name"],
                                 "line1": m["line1"], "line2": m["line2"]})
        return sats or None
    except Exception as exc:
        print(f"TLE API unavailable ({exc}); using vendored snapshot")
        return None


# ── Orbital math ───────────────────────────────────────────────────────────────

def propagate(sat, when):
    """Return (lat, lon, alt_km, velocity_kms) for a satellite at a datetime."""
    jd, fr = jday(when.year, when.month, when.day,
                  when.hour, when.minute, when.second + when.microsecond / 1e6)
    err, r, v = sat["satrec"].sgp4(jd, fr)
    if err != 0:
        return None
    x, y, z = r
    # TEME → geographic: rotate by Greenwich sidereal angle for longitude
    gmst_deg = (280.46061837 + 360.98564736629 * (jd + fr - 2451545.0)) % 360.0
    lon = (math.degrees(math.atan2(y, x)) - gmst_deg) % 360.0
    if lon > 180.0:
        lon -= 360.0
    lat = math.degrees(math.atan2(z, math.sqrt(x * x + y * y)))
    alt_km = math.sqrt(x * x + y * y + z * z) - EARTH_RADIUS_KM
    velocity_kms = math.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2)
    return (round(lat, 4), round(lon, 4), round(alt_km, 1), round(velocity_kms, 3))


# ── Backfill ───────────────────────────────────────────────────────────────────

def run_backfill(sats, total_rows, days):
    """COPY ~total_rows of historical telemetry ending now, oldest first."""
    end = datetime.now(timezone.utc)
    start = end - timedelta(days=days)
    per_sat = total_rows // len(sats)
    interval = timedelta(seconds=(days * 86400) / per_sat)
    print(f"backfill: {len(sats)} satellites x {per_sat} readings "
          f"(one per {interval.total_seconds():.0f}s) over {days} days = "
          f"~{per_sat * len(sats):,} rows")

    upsert_satellite_names(sats)

    # COPY batch size in rows. YugabyteDB can partially apply a large COPY
    # before surfacing a duplicate-key error; smaller batches limit fallout
    # and keep retries cheap. reading_id comes from BIGSERIAL (not COPY) so
    # explicit ids cannot collide with a half-finished prior attempt.
    copy_batch_rows = 10_000
    rows_written = 0
    t0 = time.monotonic()
    with connection() as conn:
        with conn.cursor() as cur:
            # Clear any partial prior run. Never TRUNCATE here: on hash-sharded
            # tables YugabyteDB collapses TRUNCATE to one tablet and breaks the
            # demo's 6-way write spread. DELETE keeps the pre-split layout.
            cur.execute("DELETE FROM telemetry")
            cur.execute("SELECT setval('telemetry_reading_id_seq', 1, false)")

            buf = io.StringIO()
            for tick in range(per_sat):
                tick_start = start + interval * tick
                # Stagger each satellite within the tick interval;
                # identical timestamps would hash to one bucket and make
                # the bucket index's distribution chunky.
                for i, s in enumerate(sats):
                    when = tick_start + interval * (i / len(sats))
                    pos = propagate(s, when)
                    if pos is None:
                        continue
                    buf.write(f"{s['satelliteId']}\t{when.isoformat()}\t"
                              f"{pos[0]}\t{pos[1]}\t{pos[2]}\t{pos[3]}\n")
                    rows_written += 1
                    if rows_written % copy_batch_rows == 0:
                        buf.seek(0)
                        cur.copy_expert(
                            "COPY telemetry (norad_id, ts, latitude, longitude, "
                            "altitude_km, velocity_kms) FROM STDIN", buf)
                        rate = rows_written / max(time.monotonic() - t0, 0.001)
                        print(f"  {rows_written:,} rows loaded ({rate:,.0f} rows/s)",
                              flush=True)
                        buf = io.StringIO()

            if buf.tell():
                buf.seek(0)
                cur.copy_expert(
                    "COPY telemetry (norad_id, ts, latitude, longitude, "
                    "altitude_km, velocity_kms) FROM STDIN", buf)
                rate = rows_written / max(time.monotonic() - t0, 0.001)
                print(f"  {rows_written:,} rows loaded ({rate:,.0f} rows/s)",
                      flush=True)

            # Never rewind the sequence below ids a live loader already used
            # (e.g. one that kept running across a `make refill`).
            cur.execute(
                "SELECT setval('telemetry_reading_id_seq', "
                "(SELECT COALESCE(max(reading_id), 1) FROM telemetry))")
    print(f"backfill complete: {rows_written:,} rows in {time.monotonic() - t0:,.0f}s")


def upsert_satellite_names(sats):
    with connection() as conn:
        with conn.cursor() as cur:
            psycopg2.extras.execute_values(
                cur,
                "INSERT INTO satellites (norad_id, name) VALUES %s "
                "ON CONFLICT (norad_id) DO UPDATE SET name = EXCLUDED.name",
                [(s["satelliteId"], s["name"]) for s in sats])


# ── Live mode ──────────────────────────────────────────────────────────────────

def run_live(sats, rate):
    """Insert `rate` readings per second; report measured throughput every 5s."""
    print(f"live ingest at target {rate} readings/sec across {len(sats)} satellites "
          f"(Ctrl-C to stop)")
    inserted_window = 0
    window_start = time.monotonic()
    while True:
        batch_start = time.monotonic()
        now = datetime.now(timezone.utc)
        sample = random.sample(sats, min(rate, len(sats)))
        batch = []
        # Spread timestamps across the past second. Satellites don't report
        # in lockstep, and identical ts values would all hash to the SAME
        # bucket, making the bucket index's write spread chunky instead of
        # smooth.
        for i, s in enumerate(sample):
            when = now - timedelta(seconds=i / len(sample))
            pos = propagate(s, when)
            if pos is None:
                continue
            batch.append((s["satelliteId"], when, *pos))
        try:
            with connection() as conn:
                with conn.cursor() as cur:
                    psycopg2.extras.execute_values(
                        cur,
                        "INSERT INTO telemetry (norad_id, ts, latitude, longitude, "
                        "altitude_km, velocity_kms) VALUES %s", batch)
            inserted_window += len(batch)
        except psycopg2.Error as exc:
            # Transient errors are expected when DDL runs against the table
            # mid-demo (e.g. "schema version mismatch" during CREATE INDEX
            # backfill). Drop the batch, keep flying.
            print(f"  batch dropped ({type(exc).__name__}: "
                  f"{str(exc).splitlines()[0][:100]}), retrying next tick", flush=True)

        elapsed_window = time.monotonic() - window_start
        if elapsed_window >= 5.0:
            actual = inserted_window / elapsed_window
            print(f"  {actual:,.0f} inserts/sec", flush=True)
            report_rate(actual)
            inserted_window = 0
            window_start = time.monotonic()

        # pace to one batch per second; if the DB is slow, the achieved
        # rate drops below target. That gap IS the demo signal.
        time.sleep(max(0.0, 1.0 - (time.monotonic() - batch_start)))


def report_rate(actual):
    try:
        with connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO ingest_stats (id, updated_at, inserts_per_sec) "
                    "VALUES (1, now(), %s) "
                    "ON CONFLICT (id) DO UPDATE SET updated_at = now(), "
                    "inserts_per_sec = EXCLUDED.inserts_per_sec", (round(actual),))
    except Exception:
        pass  # stats are garnish; never kill ingest over them


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backfill", action="store_true",
                        help="bulk-load historical telemetry, then exit")
    parser.add_argument("--rows", type=int, default=1_000_000,
                        help="backfill target row count (default 1M; pass --rows 3000000 or more for a heavier load)")
    parser.add_argument("--days", type=int, default=180,
                        help="backfill history length in days (default 180)")
    parser.add_argument("--rate", type=int, default=150,
                        help="live mode: readings per second (default 150)")
    parser.add_argument("--refresh-tle", action="store_true",
                        help="try to refresh TLEs from the live API first")
    args = parser.parse_args()

    sats = load_satellites(refresh=args.refresh_tle)
    # Drop satellites whose TLEs don't propagate across the demo window
    # (decayed orbits etc.) so batch sizes and row counts come out exact.
    horizon = datetime.now(timezone.utc) - timedelta(days=args.days)
    now = datetime.now(timezone.utc)
    sats = [s for s in sats if propagate(s, horizon) and propagate(s, now)]
    print(f"{len(sats)} satellites loaded "
          f"(ISS {'present' if any(s['satelliteId'] == ISS_NORAD_ID for s in sats) else 'MISSING'})")

    if args.backfill:
        run_backfill(sats, args.rows, args.days)
    else:
        upsert_satellite_names(sats)
        run_live(sats, args.rate)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
