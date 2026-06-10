-- ════════════════════════════════════════════════════════════════════════════
-- Pre-create BOTH secondary indexes (presenter mode; run by `make setup`).
--
-- Why pre-create? Index backfill on stage is a demo risk: it can take minutes
-- and, if interrupted, leaves the index invalid (the planner silently ignores
-- it). Pre-created indexes are maintained on every write, so during the demo
-- you switch between read paths instantly with pg_hint_plan hints instead of
-- running DDL in front of an audience. The self-service walkthrough
-- (sql/lab/walkthrough.sql) shows the full CREATE INDEX lifecycle instead.
--
-- Run with ysqlsh/psql (uses \gexec; split points must be literals, so we
-- compute them relative to now() and let the server build the DDL).
-- ════════════════════════════════════════════════════════════════════════════

-- Range index on time, newest first. Split points at 30/60/90/120/150 days
-- ago carve the 180-day history into 6 tablets; computed at runtime so this
-- demo works identically next year.
SELECT format(
$f$CREATE INDEX IF NOT EXISTS telemetry_by_time ON telemetry (ts DESC)
  INCLUDE (norad_id, latitude, longitude, altitude_km, velocity_kms)
  SPLIT AT VALUES ((%L), (%L), (%L), (%L), (%L))$f$,
  now() - interval '30 days',
  now() - interval '60 days',
  now() - interval '90 days',
  now() - interval '120 days',
  now() - interval '150 days')
\gexec

-- Record the boundaries for the dashboard's heat chart
DELETE FROM range_split_points;
INSERT INTO range_split_points (ordinal, lower_ts)
SELECT i, now() - (i * interval '30 days')
FROM generate_series(1, 5) AS i;

-- Bucket index: one extra leading expression turns the same time-ordered
-- index into 6 independent, evenly-loaded slices. Split points never rot.
CREATE INDEX IF NOT EXISTS telemetry_by_bucket ON telemetry
  ((yb_hash_code(ts) % 6) ASC, ts DESC)
  INCLUDE (norad_id, latitude, longitude, altitude_km, velocity_kms)
  SPLIT AT VALUES ((1), (2), (3), (4), (5));

-- Both indexes MUST be valid or the planner ignores them (the silent demo
-- killer). Anything false here → drop the index and re-run this file.
SELECT indexrelid::regclass AS index_name, indisvalid
FROM pg_index
WHERE indrelid = 'telemetry'::regclass
ORDER BY 1;
