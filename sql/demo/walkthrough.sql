-- ════════════════════════════════════════════════════════════════════════════
--
--   🛰️  MISSION CONTROL: demo walkthrough (presenter script, ~3 minutes)
--
--   THE STORY, told before any SQL:
--
--   You run mission control for a fleet of about 500 satellites. Real
--   ones: the data in this demo is the actual ISS, Hubble, and friends,
--   propagated from their published orbital elements. Every satellite
--   reports its position continuously, all day, forever. Your operators
--   watch a dashboard of the newest telemetry.
--
--   Everything WRITES "now". Everything READS "now". That one sentence is
--   the entire problem. This script is the fix, ending with a small
--   trade-off you make with your eyes open.
--
--   SETUP ASSUMED: `make setup` (demo mode, both indexes pre-built and
--   valid), `make load` streaming, `make dash` open. You never run DDL in
--   this script. pg_hint_plan hints switch the READ path, and the
--   dashboard's "read path" selector uses these exact hints.
--
--   BE HONEST ABOUT ONE THING: both indexes are maintained on EVERY
--   insert, so the range index's hot tablet has been hot since setup.
--   Hints only change the read path. Narrate the write side as a
--   side-by-side comparison: "here is the write path each layout gives
--   you, under identical live load." The hands-on lab
--   (sql/lab/walkthrough.sql) is where a hotspot truly appears and
--   disappears.
--
--   TIP: run every EXPLAIN twice and read the second one; the first pays
--   one-time catalog reads that are noise. For a visual before/after,
--   paste plans into plans-viewer.html (pev2, in this repo).
--
-- ════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- BEAT 1 · Performance today (the dashboard query, no index help)
-- ─────────────────────────────────────────────────────────────────────────────
-- Flip the dashboard's read path to "no index" first. Refresh sits around
-- a full second. This is why:

EXPLAIN (ANALYZE, DIST, COSTS OFF)
/*+ SeqScan(telemetry) */
SELECT norad_id, ts, latitude, longitude, altitude_km, velocity_kms
FROM telemetry
ORDER BY ts DESC
LIMIT 500;

-- READ IT BOTTOM-UP: Seq Scan reads EVERY row ("Storage Rows Scanned:
-- ~3,000,000"), Sort orders all of them, Limit keeps 500. Hash sharding
-- spread the data beautifully for writes. It also made "newest by time"
-- unanswerable without reading everything, and it gets worse every day.
--
-- Your operators are making decisions on stale telemetry. The monitoring
-- dashboard has become the source of your actual problem.


-- ─────────────────────────────────────────────────────────────────────────────
-- BEAT 2 · The obvious fix: a range index on time
-- ─────────────────────────────────────────────────────────────────────────────
-- Dashboard read path → "range index". Refresh snaps to ~2 ms.

EXPLAIN (ANALYZE, DIST, COSTS OFF)
/*+ IndexOnlyScan(telemetry telemetry_by_time) */
SELECT norad_id, ts, latitude, longitude, altitude_km, velocity_kms
FROM telemetry
ORDER BY ts DESC
LIMIT 500;

-- Index Only Scan, 500 rows instead of 3,000,000, no sort. Problem solved…
--
-- …now look at the WRITE side. The index is sorted by time and every new
-- reading has ts = NOW, so under this layout every insert lands in the
-- newest tablet:

SELECT * FROM telemetry_range_tablet_counts ORDER BY tablet_ordinal;

-- Run it again 30 seconds later: ONLY tablet 1 moves. The dashboard's
-- middle heat chart shows the same thing live, one tall bar. The base
-- table spread writes across 6 tablet leaders on 3 nodes; this index
-- funnels them through ONE tablet on ONE node. Per-node CPU at :15433
-- agrees. You bought three nodes and this index's write path uses one.
--
-- This is the classic hot shard. It bites shopping carts, order feeds,
-- event logs, any index led by a monotonically increasing value.


-- ─────────────────────────────────────────────────────────────────────────────
-- BEAT 3 · The fix that keeps both: the BUCKET index
-- ─────────────────────────────────────────────────────────────────────────────
-- Dashboard read path → "bucket index". Same index plus ONE leading
-- expression, yb_hash_code(ts) % 6: six independent, evenly loaded,
-- time-ordered slices.

EXPLAIN (ANALYZE, DIST, COSTS OFF)
/*+ IndexOnlyScan(telemetry telemetry_by_bucket) */
SELECT norad_id, ts, latitude, longitude, altitude_km, velocity_kms
FROM telemetry
ORDER BY ts DESC
LIMIT 500;

-- Two things to point at:
--   1. "Merge Streams: 6". The newest 500 from EACH bucket, read in
--      parallel and merge-sorted. The SQL did not change; the planner
--      derived the bucket predicate itself.
--   2. Still no Sort node.
--
-- (That derivation is enabled per-database by sql/core/01_schema.sql:
--    yb_enable_derived_equalities / yb_enable_derived_saops /
--    yb_max_saop_merge_streams. When a customer asks "do I have to change
--    my queries?" the answer is no, set those settings.)
--
-- Write side: every bucket grows, all the time. The right-hand heat chart
-- is six even bars, and tablet leadership is spread across all three
-- nodes:

SELECT * FROM telemetry_bucket_tablet_counts ORDER BY tablet_ordinal;
SELECT * FROM telemetry_tablet_leaders;


-- ─────────────────────────────────────────────────────────────────────────────
-- BEAT 4 · The trade-off, eyes open
-- ─────────────────────────────────────────────────────────────────────────────
--                       range index      bucket index
--   index rows read     500              3000  (500 per bucket × 6)
--   sort                none             merge of 6 pre-sorted streams
--   latency             ~2 ms            ~3–4 ms
--
-- The bucket read does 6x the index reads, paid in parallel streams, so
-- it costs a millisecond or two. In exchange: no hot tablet, all nodes on
-- the write path, an insert ceiling about 6x higher. If the table is
-- read-mostly or the key isn't monotonic, skip the bucket and use a plain
-- range index. Bucket when sustained insert rate on a time or serial key
-- is the bottleneck.


-- ─────────────────────────────────────────────────────────────────────────────
-- BEAT 5 · Where else this applies
-- ─────────────────────────────────────────────────────────────────────────────
--   · shopping carts        ("this user's items from the last week")
--   · order / payment feeds ("newest orders first" on a bigserial key)
--   · event & audit logs    ("what just happened?")
--   · IoT / metrics         (this demo)
--
-- Monotonically increasing key plus reads concentrated on the newest
-- data: bucket the index. The bucket count is yours to choose. More
-- buckets spread writes further and add streams to each read; match the
-- count to your tablets and nodes (we used 6).
--
--                                                            🛰️  fin
