# 🛰️ Mission Control — a YugabyteDB bucket index demo

You run mission control for a fleet of ~500 satellites — **real ones**: the
telemetry in this demo is the actual ISS, Hubble, and friends, computed from
their published orbital elements. Every satellite reports its position
continuously, all day, forever. Your operators watch a dashboard of the
newest readings.

**Everything writes "now". Everything reads "now".** That sentence is the
entire problem this demo is about — and the same problem hides in shopping
carts, order feeds, event logs, and any other table where an
ever-increasing key meets "show me the latest".

## What you'll see

One query carries the whole demo — the dashboard's
`SELECT … FROM telemetry ORDER BY ts DESC LIMIT 100` — through three states:

| | reads | writes |
|---|---|---|
| **1. Hash PK only** (today) | 🔴 scans all ~3M rows + sorts, every refresh | 🟢 spread across 6 tablets |
| **2. Range index on time** (the obvious fix) | 🟢 ~100 rows, single-digit ms | 🔴 every insert hits ONE hot tablet on ONE node |
| **3. Bucket index** (the fix that keeps both) | 🟢 6 parallel merge streams | 🟢 spread across 6 tablets |

State 2 is the classic trap: the index that fixes your reads quietly
funnels every write through its newest tablet. The bucket index —
`((yb_hash_code(ts) % 6), ts DESC)` — keeps time-ordered reads *and*
hash-spread writes, for a small, knowable read penalty (see
[the trade-off](#the-trade-off)).

## Quick start

### GitHub Codespaces (zero install)

1. **Code → Codespaces → Create codespace on main.** The 3-node cluster
   starts automatically (first boot takes a few minutes).
2. In the terminal: `make setup` — creates the `mission_control` database,
   loads ~3M readings of real satellite history, and pre-creates both
   indexes (a few minutes, one time).
3. Terminal 1: `make load` · Terminal 2: `make dash` → open the forwarded
   port **8501** for the dashboard, **15433** for the yugabyted UI.
4. Open `sql/03_walkthrough.sql` and step through it. To use desktop
   DBeaver instead: *Open in VS Code Desktop* — port forwarding comes with
   you, and the cluster is `localhost:5433`, database `mission_control`,
   user `yugabyte`.

### Local Docker

Same thing, minus the Codespace: `make up && make setup`, then
`make load` / `make dash`. Needs Docker with ~6 GB available memory.

## The demo (presenter path, ~3 minutes)

Everything risky is pre-done by `make setup`: both indexes already exist,
valid, and maintained on every write — you never run DDL on stage. Read
paths are switched with `pg_hint_plan` hints (the dashboard's "read path"
selector and the walkthrough's hinted EXPLAINs are the same hints). Be
honest about what that means: the write skew exists from the start —
you're comparing layouts side by side under identical live load, not
watching a hotspot appear. (The self-service path, with real DDL, shows
the appearing/disappearing version.)

1. **The story** (30 s) — the paragraph at the top of this README, in your
   own words. Dashboard read path → **no index**: live map, the real ISS,
   and the **telemetry refresh** number sitting at ~1,000 ms. "This is
   life without an index on time."
2. **Why?** (45 s) — `EXPLAIN` the dashboard query
   (walkthrough step 2): Seq Scan, *Storage Rows Scanned: ~3,000,000*,
   then a Sort, for 100 rows. Paste it into `plans-viewer.html`.
3. **Range index** (45 s) — read path → **range index**: refresh snaps to
   ~2 ms. Then the catch: the middle heat chart is one tall bar — under
   this layout every write hits one tablet on one node. You bought three
   nodes; this index's write path uses one.
4. **Bucket index** (45 s) — read path → **bucket index**: still ~3 ms,
   and the hinted EXPLAIN (step 5) shows *Merge Streams: 6*, no sort,
   same plain SQL. Right-hand heat chart: six even bars. Reads fast,
   writes spread.
5. **The trade-off** (15 s) — 600 index rows read instead of 100, in
   parallel, for ~1–2 extra ms — in exchange for no hot tablet and a ~6×
   higher insert ceiling. Close with where this applies: carts, orders,
   event logs, metrics.

Recovery: if anything looks off, `make reset` rebuilds both indexes
(before the demo, never during). If an index exists but plans ignore it,
check `pg_index.indisvalid` — walkthrough step 3 shows how.

## The self-service walkthrough (~15 minutes)

[sql/03_walkthrough.sql](sql/03_walkthrough.sql) is the demo: numbered,
narrated, runnable statement-by-statement in DBeaver, VS Code, or ysqlsh.
It includes the real `CREATE INDEX` lifecycle (with relative-date split
points you generate on the spot), index-validity checks, and warm-up notes
for clean plans. Run it with `make load` streaming in another terminal so
the hot tablet actually heats up.

## The trade-off

The bucket read scans `buckets × LIMIT` index rows (600 vs 100) and
merge-sorts 6 pre-sorted streams — a few extra milliseconds, paid in
parallel. What it buys: no hot tablet, all nodes on the write path.
Don't bucket willy-nilly: if the table is read-mostly or the key isn't
monotonic, a plain range index is the right answer. Bucket when sustained
insert rate on a time/serial key is the bottleneck.

## Repo map

```
sql/01_setup.sql        schema (telemetry: hash PK, 6 tablets)
sql/02_views.sql        per-tablet row counts + leader views
sql/03_walkthrough.sql  ⭐ THE demo script
sql/04_indexes.sql      pre-creates both indexes (run by make setup)
sql/reset.sql           drop indexes (make reset rebuilds them)
app/ingest.py           real satellite positions via SGP4; --backfill + live mode
app/dashboard.py        one-page Streamlit: map, refresh latency, heat charts
app/tle_snapshot.json   vendored orbital elements (offline fallback)
plans-viewer.html       pev2 — paste EXPLAIN output, see the plan as boxes
```

`make help` lists everything else (cluster lifecycle, fault injection,
log collection — inherited from
[yb-3node-demo](https://github.com/vickyharp/yb-3node-demo)).

## Troubleshooting

- **Node exits with code 137** — Docker ran out of memory; `make repair-node N=<n>`.
- **An index exists but the planner ignores it** — interrupted backfill left
  it invalid: `make reset`.
- **Dashboard shows "cannot query telemetry"** — run `make setup`, or the
  cluster isn't up (`make show`).
- **Live TLE refresh fails** — fine; the vendored snapshot is the data
  source. The API is charm, never load-bearing.
