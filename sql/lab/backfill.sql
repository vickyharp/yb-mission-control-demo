-- ════════════════════════════════════════════════════════════════════════════
-- Zero-app backfill: ~1M rows of telemetry history, pure SQL.
--
-- Prereqs: sql/core/schema.sql, sql/core/views.sql,
--          sql/lab/seed_satellites.sql
-- Run:     \i sql/lab/backfill.sql        (defines + runs; ~1–2 minutes)
-- Re-run:  CALL lab_backfill();           (adds rows again; TRUNCATE first
--                                          if you want a fresh start)
-- More:    CALL lab_backfill(3000000);    (heavier load; pass a row count)
--
-- Positions are synthetic-but-plausible pseudo-orbits (SQL can't propagate
-- real orbital elements; the app's ingest.py does that). What matters for
-- the lab is identical either way: timestamps densely and smoothly cover
-- the past N days, ending now.
-- ════════════════════════════════════════════════════════════════════════════

-- Deterministic pseudo-orbit: each satellite gets a period, inclination and
-- phase seeded from its norad_id. Good enough to look like telemetry.
CREATE OR REPLACE FUNCTION lab_position(
    p_norad int, p_at timestamptz,
    OUT latitude double precision, OUT longitude double precision,
    OUT altitude_km double precision, OUT velocity_kms double precision)
IMMUTABLE LANGUAGE sql AS $func$
SELECT
    round(((20 + (p_norad % 70)) *
           sin(2 * pi() * extract(epoch FROM p_at)::double precision
               / (5400 + (p_norad % 1800))))::numeric, 4)::double precision,
    round((mod((((p_norad * 73) % 360)
                + degrees(2 * pi() * extract(epoch FROM p_at)::double precision
                          / (5400 + (p_norad % 1800)))
                - extract(epoch FROM p_at)::double precision / 240.0)::numeric,
               360.0) - 180.0)::numeric, 4)::double precision,
    (400 + (p_norad % 800))::double precision,
    round((7.8 - (p_norad % 800) / 2000.0)::numeric, 3)::double precision
$func$;

CREATE OR REPLACE PROCEDURE lab_backfill(
    total_rows bigint DEFAULT 1000000,
    days       int    DEFAULT 180)
LANGUAGE plpgsql AS $proc$
DECLARE
    n_sats          int;
    ticks_total     int;
    tick_seconds    double precision;
    ticks_per_chunk int := 250;          -- ~125k rows per commit
    tick_from       int := 0;
    start_ts        timestamptz;
    t0              timestamptz := clock_timestamp();
BEGIN
    SELECT count(*) INTO n_sats FROM satellites;
    IF n_sats = 0 THEN
        RAISE EXCEPTION 'satellites is empty; run sql/lab/seed_satellites.sql first';
    END IF;

    ticks_total  := (total_rows / n_sats)::int;
    tick_seconds := days * 86400.0 / ticks_total;
    start_ts     := now() - make_interval(days => days);

    WHILE tick_from < ticks_total LOOP
        -- math inlined rather than calling lab_position(): record-returning
        -- function calls don't inline, and the per-row overhead is brutal at
        -- millions of rows (load.sql, at 150 rows/sec, uses the function)
        INSERT INTO telemetry (norad_id, ts, latitude, longitude,
                               altitude_km, velocity_kms)
        SELECT s.norad_id, r.row_ts,
               round(((20 + (s.norad_id % 70)) *
                      sin(2 * pi() * r.epoch_s / (5400 + (s.norad_id % 1800))))::numeric,
                     4)::double precision,
               round((mod((((s.norad_id * 73) % 360)
                           + degrees(2 * pi() * r.epoch_s / (5400 + (s.norad_id % 1800)))
                           - r.epoch_s / 240.0)::numeric, 360.0) - 180.0)::numeric,
                     4)::double precision,
               (400 + (s.norad_id % 800))::double precision,
               round((7.8 - (s.norad_id % 800) / 2000.0)::numeric, 3)::double precision
        FROM satellites s
        CROSS JOIN generate_series(
                 tick_from, least(tick_from + ticks_per_chunk, ticks_total) - 1
             ) AS tick
        -- stagger each satellite inside the tick so timestamps spread
        -- smoothly (identical ts values would all land in one bucket and
        -- make the bucket index's write distribution chunky)
        CROSS JOIN LATERAL (
            SELECT start_ts + make_interval(secs =>
                       tick * tick_seconds
                       + ((s.norad_id * 37) % 997) / 997.0 * tick_seconds
                   ) AS row_ts,
                   extract(epoch FROM start_ts)::double precision
                       + tick * tick_seconds
                       + ((s.norad_id * 37) % 997) / 997.0 * tick_seconds AS epoch_s
        ) r;
        COMMIT;

        tick_from := tick_from + ticks_per_chunk;
        RAISE NOTICE '% / % rows (% s elapsed)',
            least(tick_from, ticks_total) * n_sats, ticks_total * n_sats,
            round(extract(epoch FROM clock_timestamp() - t0)::numeric, 0);
    END LOOP;

    RAISE NOTICE 'backfill complete';
END $proc$;

CALL lab_backfill();

SELECT count(*) AS readings FROM telemetry;
