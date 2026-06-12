-- Index-build concurrency is caller-controlled via the :nc psql variable.
-- `make setup` passes nc=NONCONCURRENTLY: setup stops the loader first, so the
-- faster offline build is safe. Everyone else (demo-mode, reset, manual runs)
-- leaves :nc empty and gets the default online CONCURRENTLY build, which stays
-- safe while the live loader is writing.
\if :{?nc}
\else
\set nc ''
\endif

-- Range index on time, newest first. Split points at 30/60/90/120/150 days
-- ago carve the 180-day history into 6 tablets; computed at runtime so this
-- demo works identically next year.
SELECT format(
$f$CREATE INDEX %s IF NOT EXISTS telemetry_by_time ON telemetry (ts DESC)
  INCLUDE (norad_id, latitude, longitude, altitude_km, velocity_kms)
  SPLIT AT VALUES ((%L), (%L), (%L), (%L), (%L))$f$,
  :'nc',
  now() - interval '30 days',
  now() - interval '60 days',
  now() - interval '90 days',
  now() - interval '120 days',
  now() - interval '150 days')
\gexec

/*
 * If you are running this manually you may not be able to run the above 
 * in your editor of choice. This alternate SQL can create the index for you:
 * 
 * 
 create index if not exists telemetry_by_time on telemetry (ts desc)
  include (norad_id, latitude, longitude, altitude_km, velocity_kms)
  split at values (
    ('2026-05-01 00:00:00+00'),
    ('2026-04-01 00:00:00+00'),
    ('2026-03-01 00:00:00+00'),
    ('2026-02-01 00:00:00+00'),
    ('2026-01-01 00:00:00+00')
  );

 */


-- Record the boundaries for the dashboard's heat chart
DELETE FROM range_split_points;
INSERT INTO range_split_points (ordinal, lower_ts)
SELECT i, now() - (i * interval '30 days')
FROM generate_series(1, 5) AS i;

-- Bucket index: one extra leading expression turns the same time-ordered
-- index into 6 independent, evenly-loaded slices. Split points never rot.
CREATE INDEX :nc IF NOT EXISTS telemetry_by_bucket ON telemetry
  ((yb_hash_code(ts) % 6) ASC, ts DESC)
  INCLUDE (norad_id, latitude, longitude, altitude_km, velocity_kms)
  SPLIT AT VALUES ((1), (2), (3), (4), (5));

-- Both indexes MUST be valid or the planner ignores them (the silent demo
-- killer). Anything false here → drop the index and re-run this file.
SELECT indexrelid::regclass AS index_name, indisvalid
FROM pg_index
WHERE indrelid = 'telemetry'::regclass
ORDER BY 1;
