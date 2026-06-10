-- ════════════════════════════════════════════════════════════════════════════
--
--   🛰️  MISSION CONTROL: hands-on lab (~30–45 minutes, you run the DDL)
--
--   THE STORY:
--
--   You run mission control for a fleet of about 500 satellites. Every
--   satellite reports its position continuously, all day, forever. Your
--   operators watch a dashboard of the newest telemetry.
--
--   Everything WRITES "now". Everything READS "now". In this lab you will
--   feel the problem that sentence creates, build the obvious fix, watch
--   it backfire, and then build the right fix. All with your own hands.
--
--   GETTING SET UP, two equally good options:
--
--   Option A (with the app):  make setup-lab   → real satellite history
--     loaded, NO secondary indexes. Then `make load` for live telemetry
--     and `make dash` for the dashboard, whose read-path options will
--     light up as YOU create each index.
--
--   Option B (zero app code): create a database, connect to it, and run
--     these files in order with your SQL editor or CLI of choice:
--       sql/core/01_schema.sql        tables + required settings
--       sql/core/02_views.sql         observation views
--       sql/lab/seed_satellites.sql   real satellite names
--       sql/lab/backfill.sql          ~3M rows of history (~1–2 min)
--     Live load (run in a SECOND session of your client, leave it running):
--       \i sql/lab/load.sql           then:   CALL lab_load(600);
--       (or see load.sql for the \watch one-liner variant)
--
--   TIP: run every EXPLAIN twice and read the second one; the first pays
--   one-time catalog reads that are noise. Paste plans into
--   plans-viewer.html (pev2, in this repo) to see them as boxes.
--
-- ════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1 · Meet the table
-- ─────────────────────────────────────────────────────────────────────────────
-- Hash-sharded on reading_id, YugabyteDB's good default. Confirm there are
-- NO secondary indexes yet, just the primary key:

\d telemetry

SELECT count(*) AS readings FROM telemetry;

-- Writes are spread perfectly across the 6 tablets. Hash sharding is doing
-- its job. This view shows exact per-tablet counts and the Raft leader
-- node for each; it scans the table, so it takes a moment:

SELECT * FROM telemetry_hash_tablet_counts ORDER BY tablet_ordinal;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 · Feel the problem (the ONE query this whole lab is about)
-- ─────────────────────────────────────────────────────────────────────────────
-- Mission control wants the newest readings (dashboard uses LIMIT 500):

SELECT norad_id, ts, latitude, longitude, altitude_km, velocity_kms
FROM telemetry
ORDER BY ts DESC
LIMIT 500;

-- Sluggish, right? Ask the database why (run twice; read the second):

EXPLAIN (ANALYZE, DIST, COSTS OFF)
SELECT norad_id, ts, latitude, longitude, altitude_km, velocity_kms
FROM telemetry
ORDER BY ts DESC
LIMIT 500;

-- READ THE PLAN BOTTOM-UP:
--   Seq Scan  → reads EVERY row ("Storage Rows Scanned: ~3,000,000")
--   Sort      → sorts all of them to find the newest 500
--   Limit     → throws away all but 500
-- Hash sharding scattered rows by reading_id, so answering "newest by
-- time" means reading everything. About a second, every refresh, and
-- worse every day as history grows. The monitoring dashboard has become
-- the source of your actual problem.


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3 · Build the obvious fix yourself: a range index on time
-- ─────────────────────────────────────────────────────────────────────────────
-- Split points must be literals, so generate DDL relative to today: run
-- this SELECT, copy the one-row result, and execute it. Expect the CREATE
-- INDEX to take a minute or three on 3M rows. That's the online index
-- backfill working through your data, and it's exactly the cost a
-- production team pays when they add an index to a live table.

SELECT format(
$f$CREATE INDEX telemetry_by_time ON telemetry (ts DESC)
  INCLUDE (norad_id, latitude, longitude, altitude_km, velocity_kms)
  SPLIT AT VALUES ((%L), (%L), (%L), (%L), (%L))$f$,
  now() - interval '30 days',  now() - interval '60 days',
  now() - interval '90 days',  now() - interval '120 days',
  now() - interval '150 days') AS copy_paste_and_run_me;

-- Record the boundaries so the observation views (and dashboard) can show
-- which tablet each write lands in:

DELETE FROM range_split_points;
INSERT INTO range_split_points (ordinal, lower_ts)
SELECT i, now() - (i * interval '30 days') FROM generate_series(1, 5) AS i;

-- IMPORTANT HABIT: before trusting any index, check it's valid. An
-- interrupted backfill leaves indisvalid = false and the planner SILENTLY
-- ignores the index:

SELECT indexrelid::regclass AS index_name, indisvalid
FROM pg_index WHERE indrelid = 'telemetry'::regclass ORDER BY 1;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4 · Enjoy the fix…
-- ─────────────────────────────────────────────────────────────────────────────

EXPLAIN (ANALYZE, DIST, COSTS OFF)
SELECT norad_id, ts, latitude, longitude, altitude_km, velocity_kms
FROM telemetry
ORDER BY ts DESC
LIMIT 500;

-- Index Only Scan, about 500 rows read instead of 3,000,000, and no Sort
-- node because the index is already in time order. From a full second to
-- single-digit milliseconds. If you're running the dashboard, watch it
-- snap to life. Problem solved…


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 5 · …problem NOT solved: you traded a read problem for a write one
-- ─────────────────────────────────────────────────────────────────────────────
-- Make sure live load is running (Option A: make load · Option B: the
-- second session with lab_load). The index is sorted by time, and every
-- new reading has ts = NOW. So every insert lands in the SAME tablet, the
-- newest one. Watch it happen:

SELECT * FROM telemetry_range_tablet_counts ORDER BY tablet_ordinal;

-- Wait 30 seconds, run it again: ONLY tablet 1's count moves. The base
-- table spread writes across 6 tablet leaders on 3 nodes. YOUR new index
-- funnels every insert through ONE tablet on ONE node. See who's doing all
-- the work (and check per-node CPU at http://localhost:15433):

SELECT * FROM telemetry_tablet_leaders;

-- You bought three nodes and the write path of this index uses one. This
-- is the classic hot shard. It bites shopping carts, order tables, event
-- logs, any index led by a monotonically increasing value. It works fine,
-- right up until peak hour finds the ceiling of that one tablet.


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 6 · Build the right fix: the BUCKET index
-- ─────────────────────────────────────────────────────────────────────────────
-- Same index, ONE extra leading expression. yb_hash_code(ts) % 6 assigns
-- every row to one of 6 buckets, pseudo-random but deterministic. Within
-- each bucket, still time-ordered: six independent, evenly loaded slices
-- of "newest first". Bucket split points are just numbers; they never go
-- stale. Another minute or three of backfill:

CREATE INDEX telemetry_by_bucket ON telemetry
  ((yb_hash_code(ts) % 6) ASC, ts DESC)
  INCLUDE (norad_id, latitude, longitude, altitude_km, velocity_kms)
  SPLIT AT VALUES ((1), (2), (3), (4), (5));

-- Validity check, always:

SELECT indexrelid::regclass AS index_name, indisvalid
FROM pg_index WHERE indrelid = 'telemetry'::regclass ORDER BY 1;

-- Now retire the hot-tablet index so the planner's choice is unambiguous:

DROP INDEX telemetry_by_time;
DELETE FROM range_split_points;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 7 · The payoff
-- ─────────────────────────────────────────────────────────────────────────────
-- Same plain query. You change NOTHING:

EXPLAIN (ANALYZE, DIST, COSTS OFF)
SELECT norad_id, ts, latitude, longitude, altitude_km, velocity_kms
FROM telemetry
ORDER BY ts DESC
LIMIT 500;

-- Two things to notice:
--   1. "Merge Streams: 6". The newest 500 from EACH bucket, read in
--      parallel and merge-sorted. The planner derived the bucket predicate
--      (Index Cond: ... = ANY ('{0,1,2,3,4,5}')) all by itself.
--   2. Still no Sort node; each stream is pre-sorted by the index.
--
-- (That derivation needs three database settings, applied by
--  sql/core/01_schema.sql: yb_enable_derived_equalities, yb_enable_derived_saops,
--  yb_max_saop_merge_streams. Without them you'd write the predicate
--  yourself: WHERE yb_hash_code(ts) % 6 IN (0,1,2,3,4,5).)
--
-- And the write side: every bucket grows, all the time, with leaders
-- spread across all three nodes:

SELECT * FROM telemetry_bucket_tablet_counts ORDER BY tablet_ordinal;
SELECT * FROM telemetry_tablet_leaders;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 8 · The trade-off, with your eyes open
-- ─────────────────────────────────────────────────────────────────────────────
-- Compare your step-4 plan (range) with your step-7 plan (bucket):
--
--                       range index      bucket index
--   index rows read     500              3000  (500 per bucket × 6)
--   sort                none             merge of 6 pre-sorted streams
--   latency             ~2 ms            ~3–4 ms
--
-- The bucket read does 6x the index reads, in parallel streams, so you
-- pay a millisecond or two rather than 6x. What you bought: no hot
-- tablet, all nodes on the write path, an insert ceiling about 6x higher.
-- If the table is read-mostly or the key isn't monotonic, skip the bucket
-- and use a plain range index. Bucket when sustained insert rate on a
-- time or serial key is the bottleneck.


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 9 · Where else this applies, and cleaning up
-- ─────────────────────────────────────────────────────────────────────────────
--   · shopping carts        ("this user's items from the last week")
--   · order / payment feeds ("newest orders first" on a bigserial key)
--   · event & audit logs    ("what just happened?")
--   · IoT / metrics         (this lab)
--
-- Monotonically increasing key plus reads concentrated on the newest
-- data: bucket the index. The bucket count is yours to choose. More
-- buckets spread writes further and add streams to each read; match the
-- count to your tablets and nodes (we used 6).
--
-- CLEAN UP / REDO:
--   make demo-mode   → rebuild BOTH indexes (ready to show someone around)
--   make lab-mode    → drop both indexes (run this lab again)
--   make refill      → fresh 3M-row backfill if the table has grown
--   Option B users:  DROP INDEX telemetry_by_bucket; DELETE FROM
--                    range_split_points;  then start again at step 2.
--
--                                                            🛰️  fin
