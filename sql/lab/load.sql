-- ════════════════════════════════════════════════════════════════════════════
-- Zero-app live load: a stream of fresh telemetry, pure SQL.
--
-- Run this file once to define the procedure. Then, in a session you can
-- leave running (a SECOND session/tab of whatever client you use), start:
--
--     CALL lab_load(600);          -- 10 minutes at ~150 readings/sec
--     CALL lab_load(600, 300);     -- or pick your own rate
--
-- Stop early with Ctrl-C or your client's cancel button. Each 1-second batch
-- commits on its own, so cancelling never loses more than a second.
--
-- Prefer a one-liner? This does the same thing in ysqlsh:
--     INSERT INTO telemetry (norad_id, ts, latitude, longitude, altitude_km, velocity_kms)
--     SELECT s.norad_id, w.row_ts, p.* FROM (SELECT norad_id FROM satellites ORDER BY random() LIMIT 150) s
--     CROSS JOIN LATERAL (SELECT clock_timestamp() - random() * interval '1 second' AS row_ts) w
--     CROSS JOIN LATERAL lab_position(s.norad_id, w.row_ts) p
--     \watch 1
-- ════════════════════════════════════════════════════════════════════════════

-- lab_position() comes from sql/lab/backfill.sql, so run that file first.

CREATE OR REPLACE PROCEDURE lab_load(
    duration_seconds int DEFAULT 600,
    rate             int DEFAULT 150)
LANGUAGE plpgsql AS $proc$
DECLARE
    finish      timestamptz := clock_timestamp() + make_interval(secs => duration_seconds);
    batch_start timestamptz;
    inserted    int;
BEGIN
    WHILE clock_timestamp() < finish LOOP
        batch_start := clock_timestamp();

        -- the inner block swallows transient errors (e.g. "schema version
        -- mismatch" while an index backfill runs, which is expected mid-lab) so
        -- one dropped batch never kills the stream; COMMIT must live
        -- outside it (plpgsql forbids txn control in a handled block)
        BEGIN
            INSERT INTO telemetry (norad_id, ts, latitude, longitude,
                                   altitude_km, velocity_kms)
            SELECT s.norad_id, w.row_ts, p.latitude, p.longitude,
                   p.altitude_km, p.velocity_kms
            FROM (SELECT norad_id FROM satellites
                  ORDER BY random() LIMIT least(rate, (SELECT count(*) FROM satellites))) s
            -- spread timestamps across the past second; identical ts
            -- values would all hash into the same bucket
            CROSS JOIN LATERAL (
                SELECT clock_timestamp() - random() * interval '1 second' AS row_ts
            ) w
            CROSS JOIN LATERAL lab_position(s.norad_id, w.row_ts) p;
            GET DIAGNOSTICS inserted = ROW_COUNT;

            -- feed the dashboard's ingest-rate ticker (works without the app)
            INSERT INTO ingest_stats (id, updated_at, inserts_per_sec)
            VALUES (1, now(), inserted)
            ON CONFLICT (id) DO UPDATE
                SET updated_at = now(), inserts_per_sec = EXCLUDED.inserts_per_sec;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'batch dropped (%), retrying next tick',
                left(SQLERRM, 100);
        END;
        COMMIT;

        PERFORM pg_sleep(greatest(0,
            1.0 - extract(epoch FROM clock_timestamp() - batch_start)));
    END LOOP;
END $proc$;

\echo 'lab_load defined. Start the stream with:  CALL lab_load(600);'
