-- ════════════════════════════════════════════════════════════════════════════
-- Mission Control demo — schema
-- Run by `make setup` (backfill + indexes happen there too).
-- ════════════════════════════════════════════════════════════════════════════

-- The fleet: ~500 real satellites, names loaded from TLE data by ingest.py
CREATE TABLE IF NOT EXISTS satellites (
    norad_id INT  PRIMARY KEY,
    name     TEXT NOT NULL
);

-- The center of the demo: every satellite reports its position continuously.
-- PRIMARY KEY (reading_id HASH) spreads WRITES evenly across 6 tablets —
-- the standard YugabyteDB default, and a good one. The demo is about what
-- happens when you then need to READ the newest data.
CREATE TABLE IF NOT EXISTS telemetry (
    reading_id   BIGSERIAL,
    norad_id     INT              NOT NULL,
    ts           TIMESTAMPTZ      NOT NULL DEFAULT now(),
    latitude     DOUBLE PRECISION NOT NULL,
    longitude    DOUBLE PRECISION NOT NULL,
    altitude_km  DOUBLE PRECISION NOT NULL,
    velocity_kms DOUBLE PRECISION NOT NULL,
    PRIMARY KEY (reading_id HASH)
) SPLIT INTO 6 TABLETS;

-- ingest.py reports its measured throughput here; the dashboard displays it.
-- Watch this number when the range index makes every insert fight for the
-- same tablet.
CREATE TABLE IF NOT EXISTS ingest_stats (
    id              INT PRIMARY KEY,
    updated_at      TIMESTAMPTZ,
    inserts_per_sec NUMERIC
);

-- Lower bounds of the range-index tablets, recorded when the index is
-- created (sql/04_indexes.sql). The dashboard uses these to show which
-- tablet each write lands in.
CREATE TABLE IF NOT EXISTS range_split_points (
    ordinal  INT PRIMARY KEY,
    lower_ts TIMESTAMPTZ NOT NULL
);
