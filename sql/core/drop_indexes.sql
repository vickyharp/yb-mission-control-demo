-- ════════════════════════════════════════════════════════════════════════════
-- Recover from a botched run: drop both secondary indexes so they can be
-- rebuilt fresh. `make lab-mode` runs just this; `make demo-mode` runs this then sql/core/indexes.sql.
-- Data is untouched. Rebuild takes a minute or two on 3M rows, so do this
-- BEFORE the demo, never during it.
-- ════════════════════════════════════════════════════════════════════════════

DROP INDEX IF EXISTS telemetry_by_time;
DROP INDEX IF EXISTS telemetry_by_bucket;
DELETE FROM range_split_points;
