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
    """Best-effort live TLE fetch. Returns None on any failure — never load-bearing."""
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

    reading_id = 0
    t0 = time.monotonic()
    with connection() as conn:
        with conn.cursor() as cur:
            for chunk_start_idx in range(0, per_sat, 2000):
                chunk_len = min(2000, per_sat - chunk_start_idx)
                buf = io.StringIO()
                for tick in range(chunk_start_idx, chunk_start_idx + chunk_len):
                    when = start + interval * tick
                    for s in sats:
                        pos = propagate(s, when)
                        if pos is None:
                            continue
                        reading_id += 1
                        buf.write(f"{reading_id}\t{s['satelliteId']}\t"
                                  f"{when.isoformat()}\t{pos[0]}\t{pos[1]}\t{pos[2]}\t{pos[3]}\n")
                buf.seek(0)
                cur.copy_expert(
                    "COPY telemetry (reading_id, norad_id, ts, latitude, longitude, "
                    "altitude_km, velocity_kms) FROM STDIN", buf)
                done_rows = reading_id
                rate = done_rows / max(time.monotonic() - t0, 0.001)
                print(f"  {done_rows:,} rows loaded ({rate:,.0f} rows/s)", flush=True)
            cur.execute("SELECT setval('telemetry_reading_id_seq', %s)", (reading_id,))
    print(f"backfill complete: {reading_id:,} rows in {time.monotonic() - t0:,.0f}s")


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
        when = datetime.now(timezone.utc)
        batch = []
        for s in random.sample(sats, min(rate, len(sats))):
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
                  f"{str(exc).splitlines()[0][:100]}) — retrying next tick", flush=True)

        elapsed_window = time.monotonic() - window_start
        if elapsed_window >= 5.0:
            actual = inserted_window / elapsed_window
            print(f"  {actual:,.0f} inserts/sec", flush=True)
            report_rate(actual)
            inserted_window = 0
            window_start = time.monotonic()

        # pace to one batch per second; if the DB is slow, the achieved
        # rate drops below target — that gap IS the demo signal
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
    parser.add_argument("--rows", type=int, default=3_000_000,
                        help="backfill target row count (default 3M)")
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
