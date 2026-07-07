-- ════════════════════════════════════════════════════════════════════════════
-- Monitoring views: where do the rows actually live, per storage layout?
-- Created by `make setup` / `make setup-lab`; used by both walkthroughs and handy in any SQL client.
--
-- Note: these run count(*) per tablet. Fine as an on-demand check,
-- not something to poll every second. (The dashboard uses a cheaper
-- recent-sample query instead.)
-- ════════════════════════════════════════════════════════════════════════════

-- Base table: 6 hash tablets. yb_tablet_metadata exposes each tablet's hash
-- range and current Raft leader, so we can count rows per tablet exactly.
-- NOTE all views here match relations by NAME, never ::regclass; regclass
-- literals would make the views hard dependencies of the indexes (breaking
-- DROP INDEX in make reset) and would fail to create before the indexes
-- exist.
CREATE OR REPLACE VIEW telemetry_hash_tablet_counts AS
SELECT
    'base table (hash)'::text AS layout,
    row_number() OVER (ORDER BY m.start_hash_code)::int AS tablet_ordinal,
    format('hash [%s, %s)', coalesce(m.start_hash_code, 0),
           coalesce(m.end_hash_code, 65536)) AS covers,
    m.leader,
    (SELECT count(*) FROM telemetry t
      WHERE yb_hash_code(t.reading_id) >= coalesce(m.start_hash_code, 0)
        AND yb_hash_code(t.reading_id) <  coalesce(m.end_hash_code, 65536))::bigint
        AS row_count
FROM yb_tablet_metadata m
WHERE m.relname = 'telemetry'
  AND m.db_name = current_database();

-- Range index: 6 time-range tablets (ordinal 1 = newest, where now() lives).
-- Boundaries come from range_split_points, recorded at index creation.
-- Leaders come from yb_local_tablets() ordered by partition bound: the index
-- is (ts DESC), so the first partition is the newest tablet = ordinal 1.
CREATE OR REPLACE VIEW telemetry_range_tablet_counts AS
WITH tablets AS (
    SELECT i AS tablet_ordinal,
           (SELECT lower_ts FROM range_split_points WHERE ordinal = i)     AS lo,
           (SELECT lower_ts FROM range_split_points WHERE ordinal = i - 1) AS hi
    FROM generate_series(1, 6) AS i
),
leaders AS (
    SELECT row_number() OVER (ORDER BY l.partition_key_start NULLS FIRST)::int
               AS tablet_ordinal,
           m.leader
    FROM yb_local_tablets() l
    LEFT JOIN yb_tablet_metadata m ON m.tablet_id = l.tablet_id
    WHERE l.table_name = 'telemetry_by_time'
      AND l.namespace_name = current_database()
)
SELECT
    'range index (time)'::text AS layout,
    t.tablet_ordinal,
    CASE
      WHEN hi IS NULL THEN format('ts >= %s  ← ALL new writes land here', lo::date)
      WHEN lo IS NULL THEN format('ts < %s', hi::date)
      ELSE format('ts [%s, %s)', lo::date, hi::date)
    END AS covers,
    ldr.leader,
    (SELECT count(*) FROM telemetry x
      WHERE (lo IS NULL OR x.ts >= lo)
        AND (hi IS NULL OR x.ts < hi))::bigint AS row_count
FROM tablets t
LEFT JOIN leaders ldr USING (tablet_ordinal);

-- Bucket index: 6 buckets by yb_hash_code(ts) % 6. Every bucket keeps
-- receiving new writes. That is the whole point.
CREATE OR REPLACE VIEW telemetry_bucket_tablet_counts AS
WITH counts AS (
    SELECT (yb_hash_code(ts) % 6)::int AS bucket, count(*)::bigint AS row_count
    FROM telemetry
    GROUP BY 1
),
leaders AS (
    SELECT row_number() OVER (ORDER BY l.partition_key_start NULLS FIRST)::int
               AS tablet_ordinal,
           m.leader
    FROM yb_local_tablets() l
    LEFT JOIN yb_tablet_metadata m ON m.tablet_id = l.tablet_id
    WHERE l.table_name = 'telemetry_by_bucket'
      AND l.namespace_name = current_database()
)
SELECT
    'bucket index (hash(ts) % 6)'::text AS layout,
    c.bucket + 1 AS tablet_ordinal,
    format('bucket %s', c.bucket) AS covers,
    ldr.leader,
    c.row_count
FROM counts c
LEFT JOIN leaders ldr ON ldr.tablet_ordinal = c.bucket + 1;

-- Which node leads how many tablets of each layout? With the range index
-- under live load, the single hot tablet means ONE node coordinates all the
-- index writes; the bucket index spreads leadership (and writes) across all
-- three. The leader columns are the honest signal here; per-node CPU is
-- muddied by every client connecting through node1.
CREATE OR REPLACE VIEW telemetry_tablet_leaders AS
SELECT relname AS layout, leader, count(*) AS tablets
FROM yb_tablet_metadata
WHERE relname IN ('telemetry', 'telemetry_by_time', 'telemetry_by_bucket')
  AND db_name = current_database()
GROUP BY relname, leader
ORDER BY relname, leader;
