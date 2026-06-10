-- ════════════════════════════════════════════════════════════════════════════
--
--   🛰️  MISSION CONTROL — why your monitoring dashboard became the problem
--
--   THE STORY (say this first, before any SQL):
--
--   You run mission control for a fleet of ~500 satellites — real ones; the
--   data in this demo is the actual ISS, Hubble, and friends, propagated
--   from their published orbital elements. Every satellite reports its
--   position continuously, all day, forever. Your operators watch a
--   dashboard of the newest telemetry.
--
--   Everything WRITES "now". Everything READS "now". That one sentence is
--   the entire problem, and this walkthrough is how to fix it — ending with
--   a small trade-off you should make with your eyes open.
--
--   HOW TO RUN: step through statement by statement in DBeaver / VS Code
--   SQLTools / ysqlsh. `make setup` already loaded ~3M rows of history and
--   `make load` is streaming live telemetry. Steps 3 and 5 each have a
--   PRESENTER variant (hint, instant) and a SELF-SERVICE variant (real DDL).
--
--   PRESENTER MODE, BE HONEST ABOUT ONE THING: both indexes already exist
--   and are maintained on EVERY insert — the range index's hot tablet has
--   been hot since setup, hints only change the READ path. So narrate it
--   as a side-by-side comparison: "here is the write path each layout
--   gives you, under identical live load." Only the self-service path
--   (real CREATE/DROP INDEX) shows the hotspot appearing and disappearing.
--
--   TIP (plans): run every EXPLAIN twice and read the second one — the
--   first pays one-time catalog reads that are noise. For a visual
--   before/after, paste plans into plans-viewer.html (pev2) in this repo.
--
-- ════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1 · Meet the table (performance today)
-- ─────────────────────────────────────────────────────────────────────────────
-- Hash-sharded on reading_id — YugabyteDB's good default. Writes spread
-- evenly across 6 tablets on 3 nodes. Nothing is wrong with this table…

\d telemetry

SELECT count(*) AS readings FROM telemetry;

-- …and the writes prove it: perfectly balanced. (Exact per-tablet counts +
-- Raft leader for each tablet. This scans the table — it takes a second.)

SELECT * FROM telemetry_hash_tablet_counts ORDER BY tablet_ordinal;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2 · The dashboard query (the ONE query this whole demo is about)
-- ─────────────────────────────────────────────────────────────────────────────
-- Mission control wants the newest 100 readings. Watch the dashboard while
-- you're here: its "telemetry refresh" number IS this query.

SELECT norad_id, ts, latitude, longitude, altitude_km, velocity_kms
FROM telemetry
ORDER BY ts DESC
LIMIT 100;

-- Why so slow? Ask the database. (Run twice; read the second.)

EXPLAIN (ANALYZE, DIST, COSTS OFF)
SELECT norad_id, ts, latitude, longitude, altitude_km, velocity_kms
FROM telemetry
ORDER BY ts DESC
LIMIT 100;

-- READ THE PLAN BOTTOM-UP — paste it into plans-viewer.html to see it:
--   Seq Scan      → reads EVERY row ("Storage Rows Scanned: ~3,000,000")
--   Sort          → sorts all 3M rows to find the newest 100
--   Limit         → throws away all but 100
-- Hash sharding scattered the data by reading_id, so "newest by time" is
-- answerable only by reading everything. About a full second, every refresh,
-- and it gets WORSE every day as history grows.
--
-- Your operators are making dispatch decisions on stale telemetry. The
-- monitoring dashboard has become the source of your actual problem.


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3 · The obvious fix: a range index on time   (intermediate step)
-- ─────────────────────────────────────────────────────────────────────────────

-- PRESENTER PATH — index already exists (make setup), just steer the planner:

EXPLAIN (ANALYZE, DIST, COSTS OFF)
/*+ IndexOnlyScan(telemetry telemetry_by_time) */
SELECT norad_id, ts, latitude, longitude, altitude_km, velocity_kms
FROM telemetry
ORDER BY ts DESC
LIMIT 100;

-- SELF-SERVICE PATH — build it for real and feel the backfill. Split points
-- must be literals, so generate the DDL relative to today: run this SELECT,
-- copy the one-row result, execute it. (~1–3 min on 3M rows. While it
-- backfills: this is exactly why the presenter path pre-creates indexes —
-- never run this in front of an audience.)
/*
SELECT format(
$f$CREATE INDEX telemetry_by_time ON telemetry (ts DESC)
  INCLUDE (norad_id, latitude, longitude, altitude_km, velocity_kms)
  SPLIT AT VALUES ((%L), (%L), (%L), (%L), (%L))$f$,
  now() - interval '30 days',  now() - interval '60 days',
  now() - interval '90 days',  now() - interval '120 days',
  now() - interval '150 days') AS copy_paste_and_run_me;

DELETE FROM range_split_points;
INSERT INTO range_split_points (ordinal, lower_ts)
SELECT i, now() - (i * interval '30 days') FROM generate_series(1, 5) AS i;
*/

-- EITHER WAY — before trusting any index, check it's valid. An interrupted
-- backfill leaves indisvalid = false and the planner SILENTLY ignores it:

SELECT indexrelid::regclass AS index_name, indisvalid
FROM pg_index WHERE indrelid = 'telemetry'::regclass ORDER BY 1;

-- The new plan: Index Only Scan, ~100 rows read instead of 3,000,000, no
-- sort (the index is already in time order). From ~1 second to single-digit
-- ms. The dashboard snaps to life. Problem solved…


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4 · …problem NOT solved: we traded a read problem for a write problem
-- ─────────────────────────────────────────────────────────────────────────────
-- The index is sorted by time. Every new reading has ts = NOW. So every
-- write — 150/sec, from every satellite — lands in the SAME tablet: the
-- newest one. (Presenter mode: this has been true since `make setup` —
-- the index absorbs every insert whether or not your reads use it. You're
-- revealing the skew, not causing it.) Look at tablet 1:

SELECT * FROM telemetry_range_tablet_counts ORDER BY tablet_ordinal;

-- Run it again ~30 seconds later: ONLY tablet 1's count moves. The base
-- table spread writes across 6 tablet leaders on 3 nodes; this index
-- funnels every insert through ONE tablet on ONE node. Check who's doing
-- all the work (and watch per-node CPU at http://localhost:15433):

SELECT * FROM telemetry_tablet_leaders;

-- On the dashboard, the middle heat chart shows it live: one tall bar.
-- You bought three nodes; on the write path of this index you're using one.
-- This is the classic hot shard — same thing that bites shopping carts,
-- order tables, event logs: any index led by a monotonically increasing
-- value. The system works… until your peak hour finds the ceiling of that
-- one tablet.


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 5 · The fix that keeps both: a BUCKET index            (final step)
-- ─────────────────────────────────────────────────────────────────────────────
-- Same index, one extra leading expression: yb_hash_code(ts) % 6 assigns
-- every row to one of 6 buckets, pseudo-randomly but deterministically.
-- Within each bucket, still ordered by time. Six independent, evenly-loaded
-- slices of "newest first".

-- PRESENTER PATH — it's pre-created; steer the planner at it:

EXPLAIN (ANALYZE, DIST, COSTS OFF)
/*+ IndexOnlyScan(telemetry telemetry_by_bucket) */
SELECT norad_id, ts, latitude, longitude, altitude_km, velocity_kms
FROM telemetry
ORDER BY ts DESC
LIMIT 100;

-- SELF-SERVICE PATH — split points are just bucket numbers; they never rot:
/*
CREATE INDEX telemetry_by_bucket ON telemetry
  ((yb_hash_code(ts) % 6) ASC, ts DESC)
  INCLUDE (norad_id, latitude, longitude, altitude_km, velocity_kms)
  SPLIT AT VALUES ((1), (2), (3), (4), (5));

-- then re-check pg_index.indisvalid as in step 3
*/

-- READ THE PLAN — two things to notice:
--   1. "Merge Streams: 6" — YugabyteDB reads the newest 100 from EACH
--      bucket in parallel and merge-sorts them. No client changes, no
--      WHERE clause changes: the planner did this to a plain ORDER BY.
--   2. Still no Sort node — each stream is pre-sorted by the index.
--
-- (That planner magic is enabled per-database by `make setup`:
--    yb_enable_derived_equalities = true
--    yb_enable_derived_saops      = true
--    yb_max_saop_merge_streams    = 64
--  Without these, you must spell out the buckets yourself:
--  WHERE yb_hash_code(ts) % 6 IN (0,1,2,3,4,5). Worth saying out loud
--  when a customer asks "do I have to change my queries?" — no, but
--  set these settings.)
--
-- And the write side — every bucket grows, all the time:

SELECT * FROM telemetry_bucket_tablet_counts ORDER BY tablet_ordinal;
SELECT * FROM telemetry_tablet_leaders;

-- Dashboard: right-hand heat chart shows six even bars; ingest rate is
-- back to target. Reads fast AND writes spread. Both problems gone.


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 6 · The trade-off, with your eyes open
-- ─────────────────────────────────────────────────────────────────────────────
-- Compare the two index plans above (paste both into plans-viewer.html):
--
--                       range index      bucket index
--   index rows read     100              600   (100 per bucket × 6)
--   sort                none             merge of 6 pre-sorted streams
--   latency             ~single-digit ms ~slightly more
--
-- The bucket read does 6× the index reads — but they run as parallel
-- streams, so you pay a few extra milliseconds, not 6×. That small read
-- penalty buys you: no hot tablet, all nodes on the write path, and an
-- insert ceiling 6× higher.
--
-- So don't bucket willy-nilly: if your table is read-mostly or the indexed
-- column isn't monotonic, a plain range index is the right answer. Bucket
-- when sustained insert rate on a time/serial key is the bottleneck.


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 7 · Where else this applies
-- ─────────────────────────────────────────────────────────────────────────────
-- The pattern — monotonically increasing key, reads concentrated on the
-- newest data — is everywhere:
--
--   · shopping carts        ("show this user's items from the last week")
--   · order / payment feeds ("newest orders first" on a bigserial key)
--   · event & audit logs    ("what just happened?")
--   · IoT / metrics         (this demo)
--
-- If inserts keep climbing and every read wants "the latest", the bucket
-- index is how a distributed SQL database gives you both. The number of
-- buckets is yours to choose: more buckets = more write spread, more
-- streams per read. Match it to your tablet/node count (we used 6).
--
--                                                            🛰️  fin
