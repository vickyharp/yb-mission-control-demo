/* ════════════════════════════════════════════════════════════════════════════
*   LAB MODE
*  
*   The SQL in this file is intended to help you walk through a full scenario
*   of adding and testing indexes to learn about bucket indexes. If you just
*   want the highlights, run make setup and use demo mode. If you are running
*   this and indexes already exist, make setup-lab will drop the indexes and
*   get you to a good spot. 
* 
*   Best option: Use make load to start the load generator
*   and make dash to start the dashboard.
*
*   If you don't want to use make, or can't get it to work, you will need to
*   set up the schema manually and you can either use the load generator
*   or even use a pure sql implementation of the loader. This is a bit harder
*   but available if you have a limitation keeping you from running the app:
* 
*     Create a database, connect to it, and run these files in order:
*      sql/core/schema.sql        tables + required settings
*       sql/core/views.sql         observation views
*       sql/lab/seed_satellites.sql   real satellite names
*       sql/lab/backfill.sql          ~1M rows of history (~1–2 min)
*     Live load if desired:   read sql/lab/load.sql and follow directions
*
*   TIP: run every EXPLAIN twice and read the second one; the first pays
*   one-time catalog reads that are noise. 
  ════════════════════════════════════════════════════════════════════════════ */


/*
 * This is the table the dashboard draws from (should already be 
 * created from the above instructions, listed for reference)
 * 
 * Every satellite reports its position continuously.
 * the hashed primary key spreads writes evenly across 6 tablets. 
 * This structure works well for point lookups, but because
 * ordering is lost, it becomes an issue for range searches
 * 
 */
create table if not exists telemetry (
    reading_id   bigserial,
    norad_id     int              not null,
    ts           timestamptz      not null default now(),
    latitude     double precision not null,
    longitude    double precision not null,
    altitude_km  double precision not null,
    velocity_kms double precision not null,
    primary key (reading_id hash)
) split into 6 tablets;

-- View the rowcount as FYI
select count(*) as readings from telemetry;

-- View the distribution of rows across the tablets
select * from telemetry_hash_tablet_counts order by tablet_ordinal;


/* 
 * The effect can be seen in the dashboard on the "no index" view, which
 * runs the following query. 
 */
select norad_id, ts, latitude, longitude, altitude_km, velocity_kms
from telemetry
order by ts desc
limit 500;

/* 
 * Let's take a look at the plan
 * (Read from the bottom up, if not already familiar)
 * 
 * You'll see a sequential scan reading all of the rows 
 * (look for "storage rows scanned"), followed by a sort of
 * that entire set to find the newest 500, and then all but 500
 * of those rows are thrown out by the limit.
 * 
 * Basically this query is going to take a little longer to run
 * every time there is an insert.
 * 
 */
explain (analyze, dist, costs off)
select norad_id, ts, latitude, longitude, altitude_km, velocity_kms
from telemetry
order by ts desc
limit 500;


/*
 * Switching to a range index will fix the read issue.
 * 
 * To keep this demo relevant to whenever you are running it, we're
 * going to make the split points going back in time from the day 
 * you are running this, so this next line will output the SQL
 * to generate the index with the right split points.
 * 
 */
SELECT format(
$f$CREATE INDEX telemetry_by_time ON telemetry (ts DESC)
  INCLUDE (norad_id, latitude, longitude, altitude_km, velocity_kms)
  SPLIT AT VALUES ((%L), (%L), (%L), (%L), (%L))$f$,
  now() - interval '30 days',  now() - interval '60 days',
  now() - interval '90 days',  now() - interval '120 days',
  now() - interval '150 days') AS copy_paste_and_run_me;

-- Paste the index creation SQL here and run it:

select 1 as "Put index create here!";

/*
 * Next we need to record what those split points were
 * so that some of our supporting views can help show you
 * where the writes are landing
 */

delete from range_split_points;
insert into range_split_points (ordinal, lower_ts)
select i, now() - (i * interval '30 days') from generate_series(1, 5) as i;

/*
 * Creating that index might take a minute and you want to make
 * sure the backfill finished and the index is valid before
 * moving on in the lab
 * 
 * No reason to think it won't work fine, but if you have a hiccup,
 * drop and recreate the index
 */
select indexrelid::regclass as index_name, indisvalid
from pg_index where indrelid = 'telemetry'::regclass order by 1;


/*
 * Now let's run that same query as before and see how fast it runs,
 * and check out the plan
 * 
 * You'll see an index only scan that reads only the 500 rows that
 * it needs - no sort is necessary because it's already in order
 * 
 * This is likely going to be a switch from 1000 to more like 5 milliseconds
 */
explain (analyze, dist, costs off)
select norad_id, ts, latitude, longitude, altitude_km, velocity_kms
from telemetry
order by ts desc
limit 500;

/*
 * Make sure the load generator is running (make load, or the 
 * lab load option described in the header)
 * 
 * Now let's take a look at where those writes are landing
 */

select * from telemetry_range_tablet_counts order by tablet_ordinal;

/*
 * Wait a few seconds, and run it again. Only tablet 1 will be
 * showing movement. The base table spreads writes across 6 tablets
 * and 3 nodes, but this index creates a hot single tablet on one node.
 *
 * The leader column is the tell: one node is coordinating every write
 * to that tablet. (Per-node CPU is a muddy signal here because the
 * load generator connects through node1 either way; trust the leader
 * column instead.)
 */
select * from telemetry_range_tablet_counts order by tablet_ordinal;



-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 6 · Build the right fix: the BUCKET index
-- ─────────────────────────────────────────────────────────────────────────────
-- Same index, ONE extra leading expression. yb_hash_code(ts) % 6 assigns
-- every row to one of 6 buckets, pseudo-random but deterministic. Within
-- each bucket, still time-ordered: six independent, evenly loaded slices
-- of "newest first". Bucket split points are just numbers; they never go
-- stale. Another minute or three of backfill:

/*
 * Now let's use a bucket index
 * 
 * This is fundamentally still a range index, but there is an extra 
 * leading expression compared to the prior index. yb_hash_code(ts) % 6
 * assigns every row to one of 6 buckets in a pseudo-random but 
 * deterministic way. The first column of every row in that bucket's
 * tablet is 0-6, and the second column is sorted by the second column
 * of the index, which is ts. 
 */
create index telemetry_by_bucket on telemetry
  ((yb_hash_code(ts) % 6) asc, ts desc)
  include (norad_id, latitude, longitude, altitude_km, velocity_kms)
  split at values ((1), (2), (3), (4), (5));

-- Validity check, just in case
select indexrelid::regclass as index_name, indisvalid
from pg_index where indrelid = 'telemetry'::regclass order by 1;

-- Now drop the prior hot-tablet index so the planner's choice is unambiguous:
drop index telemetry_by_time;
delete from range_split_points;

/*
 * Now let's run that query again. We've not changed the original
 * SQL being run by the dashboard at all, only the underlying
 * structures. 
 * 
 * A few things to notice:
 * 1) You now get 500 reads per bucket - not the full table scan from before
 * but also not just 500 total. The total you'll see for index rows
 * scanned is 3000.
 * 2) You can see Merge Streams: 6 - this lets you know that there are 6 parallel
 * streams reading 500 apiece
 * 2) Because the data is sorted within the buckets, the sort is also happening
 * during the merge, and you can see the merge sort key, but no separate SORT
 * step after the index scan
 */
explain (analyze, dist, costs off)
select norad_id, ts, latitude, longitude, altitude_km, velocity_kms
from telemetry
order by ts desc
limit 500;

/* 
 * If you're not seeing the bucket index being used, be sure that 
 * your database settings are correct (which would be set up automatically by
 * the make setup / make setup-lab options)
 * 
 * These flags turn on yb_enable_derived_equalities, yb_enable_derived_saops,
 * and yb_max_saop_merge_streams
 */


/* 
 * Now, looking at the write side - writes are being distributed across the buckets
 * as they were with the hash index, eliminating the hotspot
 */
select * from telemetry_bucket_tablet_counts order by tablet_ordinal;

/*
 * Want to run this again?
 * 
 * make demo-mode: rebuild BOTH indexes (ready to show someone around)
 * make refill: fresh 1M-row backfill if you need it
 * 
 * Or, manually drop the index and re-run from the top here
 * drop index telemetry_by_bucket; 
 */

