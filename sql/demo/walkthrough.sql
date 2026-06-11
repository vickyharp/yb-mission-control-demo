/* ════════════════════════════════════════════════════════════════════════════
*   DEMO MODE
*  
*   The SQL in this file is intended to help with a fast demo where you
*   do not want to build and drop indexes as you go. If you have run
*   make setup, the table and 3 indexes are already created and this
*   SQL will use plan hints to switch among them to see the different plans.
*
*   This is not a real world setup, because now you have both indexes 
*   being maintained on every insert amd you will have the hot tablet for 
*   the range index even when you have the bucket index available to 
*   satisfy queries. The hands-on lab (sql/lab/walkthrough.sql) is where 
*   a hotspot truly appears and disappears.
*
*   TIP: run every EXPLAIN twice and read the second one; the first pays
*   one-time catalog reads that are noise. 
  ════════════════════════════════════════════════════════════════════════════ */



/*
 * This is the table the dashboard draws from
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

/* 
 * The effect can be seen in the dashboard on the "no index" view, which
 * runs the following query. The explain plan shows a scan, a sort, and 
 * then a limit, and it reads every row in the table
 */

explain (analyze, dist, costs off)
/*+ seqscan(telemetry) */
select norad_id, ts, latitude, longitude, altitude_km, velocity_kms
from telemetry
order by ts desc
limit 500;

/*
 * This shows the tablets for the base table
 */
select * from telemetry_hash_tablet_counts order by tablet_ordinal;

/*
 * Switching to a range index will fix the read issue. The actual index
 * created by the make setup will split at 30 day intervals relative to the
 * day the demo is created, but for easy reference, this is what the index looks
 * like in general
 */
create index if not exists telemetry_by_time on telemetry (ts desc)
  include (norad_id, latitude, longitude, altitude_km, velocity_kms)
  split at values (
    ('2026-05-01 00:00:00+00'),
    ('2026-04-01 00:00:00+00'),
    ('2026-03-01 00:00:00+00'),
    ('2026-02-01 00:00:00+00'),
    ('2026-01-01 00:00:00+00')
  );

/* 
 * This is the same query as above with just a different plan hint to use
 * the range index. It now reads only the exact 500 rows necessary because
 * it is able to scan in order, no sort required.
 */
explain (analyze, dist, costs off)
/*+ indexonlyscan(telemetry telemetry_by_time) */
select norad_id, ts, latitude, longitude, altitude_km, velocity_kms
from telemetry
order by ts desc
limit 500;

/*
 * The problem is that all of these 500 rows, and all of the rows being inserted
 * by the load generator, are landing on the same tablet. If the load
 * generator is running you can run this a few times to see the numbers shift
 */
select * from telemetry_range_tablet_counts order by tablet_ordinal;


/*
 * So here is where we can create a bucket index, which creates 6 buckets 
 * on the hash of ts, then orders the next column exactly as it did 
 * in the range query above
 */
create index if not exists telemetry_by_bucket on telemetry
  ((yb_hash_code(ts) % 6) asc, ts desc)
  include (norad_id, latitude, longitude, altitude_km, velocity_kms)
  split at values ((1), (2), (3), (4), (5));


/* 
 * Once again, this is the same query as above, hinted to use
 * the bucket index. It is doing 500 reads per bucket, and then merging them
 * without a sort, and taking the limit 500 on the top of that. This means
 * you're doing 3000 reads instead of 500, but those are balanced across the 
 * buckets, and as we will see, we don't have the hot shard anymore
 * 
 * You don't actually need this hint, either: this is the query the planner
 * will pick automatically. The hint is here for consistency.
 */
explain (analyze, dist, costs off)
/*+ indexonlyscan(telemetry telemetry_by_bucket) */
select norad_id, ts, latitude, longitude, altitude_km, velocity_kms
from telemetry
order by ts desc
limit 500;


/*
 * And you can see how the load is spread across the tablets
 */
select * from telemetry_bucket_tablet_counts order by tablet_ordinal;