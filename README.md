# 🛰️ Mission Control: a YugabyteDB bucket index demo

This repo sets up a 3-node YugabyteDB cluster and a live dashboard to demonstrate bucket-based indexing. The workload is a fleet of ~500 real satellites, including the ISS, Hubble, and friends, computed from their published orbital elements using the [TLE API](https://tle.ivanstanojevic.me). Every satellite reports its position continuously, all day, forever.

You can run it right here on GitHub with no install, or clone it and run locally with Docker. [![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/vickyharp/yb-mission-control-demo) or jump to [Setup instructions](#get-it-running). Otherwise, read on to find out more about the problem space.

## Bucket Based Indexes in YugabyteDB

YugabyteDB is an open-source distributed SQL database built on a PostgreSQL-compatible query layer. It runs your existing Postgres SQL and drivers unchanged, while spreading data and workload across multiple nodes with built-in replication and fault tolerance.

When YugabyteDB creates a table, it splits the data into tablets, each owning a slice of the keyspace. This demo uses 6 tablets across 3 nodes. Every tablet has one leader and two replicas on the other nodes, so the cluster tolerates a node failure without losing data or availability. With 6 tablets and 3 nodes, each node leads 2 tablets and holds replica copies of the remaining 4, keeping load balanced and participating in the Raft quorum for every tablet in the cluster.

The core question: given that both reads and writes are chasing "now" because the index key is a timestamp, what's the right way to shard the table?

The two standard approaches are range sharding, where each tablet owns a contiguous slice of values, and hash sharding, where every key is hashed to spread rows evenly. A monotonically increasing key breaks both. Range sharding keeps range queries fast but funnels all new writes onto the newest tablet (which is also where all the reads are landing). Hash sharding spreads writes evenly but turns a range query into a full scan on every tablet because there is no inherent sort order.

Bucket-based indexing takes a different approach: hash the key into a small number of buckets and sort within each bucket. Writes spread across buckets; range reads merge a small number of sorted streams.

## What you'll see

One query carries everything. It's the dashboard's
`SELECT … FROM telemetry ORDER BY ts DESC LIMIT 500`, and you'll watch it
go through three states:

| | reads | writes |
|---|---|---|
| **1. Hash PK only** (today) | 🔴 scans all ~1M rows + sorts, noticeably slow every refresh | 🟢 spread across 6 tablets |
| **2. Range index on time** (the obvious fix) | 🟢 500 rows, ~2 ms | 🔴 every insert hits ONE hot tablet on ONE node |
| **3. Bucket index** (the fix that keeps both) | 🟢 6 parallel merge streams, no sort, ~3 ms | 🟢 spread across 6 tablets on 3 nodes |

State 2 is the classic trap. The index that fixes your reads also
funnels every write through its newest tablet. You can see this in the dashboard. All writes land on one tablet, which means one node is absorbing all the write load.

The bucket index,
`((yb_hash_code(ts) % 6), ts DESC)`, keeps time-ordered reads and
hash-spread writes at the same time. Reads and writes both run with the full parallelism of all 3 nodes.

There is a tradeoff to using the bucket instead of a pure range. Each read scans 3,000 index rows instead of 500 (the newest 500 from each bucket), merge-sorted in
parallel for an extra millisecond or two. In exchange you get rid of the
hot tablet, put every node on the write path, and raise the insert ceiling
about 6x. It's a good trade for this kind of workload, but if your table is read-mostly, or the key isn't monotonic, skip the bucket and use a plain range index.

## Choose your  path

This repository has both a demo mode and a lab mode.

| | **🎬 Demo** | **🧪 Lab** |
|---|---|---|
| You want to… | show someone around, or watch the story unfold | learn by doing; you run the DDL |
| Time | ~3 minutes | ~30–45 minutes |
| Indexes | pre-built; you switch read paths with hints | none at start; **you** create them and watch what happens |
| Setup command | `make setup` | `make setup-lab` |
| Your script | [sql/demo/walkthrough.sql](sql/demo/walkthrough.sql) | [sql/lab/walkthrough.sql](sql/lab/walkthrough.sql) |

First time here? Have a few minutes? Try the lab. The slow query, the hot tablet, and the fix
all happen because of statements you ran, and that sticks. If you want a quick overview, the demo runs without even pulling down this repo.

You can switch a running system any time using `make demo-mode` or `make lab-mode`.

The dashboard's **Controls** page does the same with buttons, and its read-path options light up as indexes
appear.

## Get it running

1. **Start the cluster.**
   - *GitHub Codespaces (zero install):* **Code → Codespaces → Create
     codespace on main.** The cluster starts and **demo mode setup runs
     automatically** (~1M rows + both indexes). First boot takes several
     minutes; once it finishes everything is ready with no further waiting.
     **[CODESPACES.md](CODESPACES.md)** opens in the editor and
     `make welcome` prints status anytime. Use a **4-core / 8 GB+** machine
     type when you can.
   - *Local devcontainer (Reopen in Container):* same auto demo setup as
     Codespaces when you open the devcontainer.
   - *Local Docker on the host:* `make up`. Give Docker ~6 GB of memory.
     **No auto data load** — you run setup yourself (step 2).
2. **Pick your mode** (local Docker and retries): `make setup` or
   `make setup-lab`. Either one creates the `mission_control` database and
   loads ~1M readings of real satellite history. A minute or two, one time.
   Codespaces/devcontainer skip this step unless bootstrap failed or you
   deleted the data (`make clean` wipes volumes and triggers a fresh load
   on the next start). Long-running Codespaces may need `make refill`
   before presenting. Want a bigger table (e.g. for a beefier machine or
   to make the seq scan hurt more)? `make setup ROWS=3000000` or
   `make refill ROWS=3000000`.
3. **Bring it to life.** Run `make load` in one terminal for live
   telemetry writes, and `make dash` in another for the dashboard on port
   **8501** (auto-forwarded in a Codespace).
4. **Open your script**, `sql/demo/walkthrough.sql` or
   `sql/lab/walkthrough.sql`, in any SQL editor or CLI and step through
   it. The dashboard's **Connect** page explains how to point your tools
   at the cluster, locally or from a Codespace.

### Lab without any app code

Prefer to skip Python entirely? The whole lab runs from a SQL session.
Create a database and connect to it (`make db` does this, or plain
`CREATE DATABASE mission_control;` works), then run these in order:

```
sql/core/schema.sql          tables + required database settings
sql/core/views.sql           observation views
sql/lab/seed_satellites.sql     real satellite names
sql/lab/backfill.sql            ~1M readings of history (~1–2 min)
```

For live load, open a second session, run `sql/lab/load.sql`, then
`CALL lab_load(600);`. That gives you ten minutes of ~150 writes/sec, and
you can cancel any time. The lab walkthrough covers this path as Option B
in its header.

## Demo mode notes (presenting)

`make setup` pre-builds all of the indexes so you don't need to wait for DDL to run while you are doing a demo. Instead of creating the indexes inline, the demo
switches read paths with `pg_hint_plan` hints. The dashboard's
read-path selector and the walkthrough's `EXPLAIN`s use the same hints,
so the page and the plans always tell one story. A script lives in
[sql/demo/walkthrough.sql](sql/demo/walkthrough.sql) with the talking
points inline if you want to step through it.

One point to note: in demo mode, you have both the range and bucket indexes created from the get go. That means both indexes absorb every write from the moment setup finishes, so write distribution numbers don't reflect what you'd see with only one index active.

The lab is where a hotspot truly appears and disappears because you are actively creating and deleting indexes as you go.

Before you present: `make demo-mode` for fresh, definitely-valid indexes,
and `make refill` if a long-running loader has grown the table.

## Lab mode notes (learning)

[sql/lab/walkthrough.sql](sql/lab/walkthrough.sql) is numbered, narrated,
and runnable statement by statement. You'll see the original one-second query,
generate the range-index DDL with split points relative to today, and
learn to check `pg_index.indisvalid` before trusting any index. Then you
watch your new index funnel every live write into one tablet, build the
bucket index, and watch the planner adopt it.

Each `CREATE INDEX` takes a minute or two on 1M rows (longer if you loaded more).

Finished, or want to start over? `make lab-mode` drops the indexes and
`make refill` resets the data.

## Repo map

```
Makefile                      every command mentioned here; see `make help`
sql/core/schema.sql        tables (telemetry: hash PK, 6 tablets)
sql/core/views.sql         per-tablet row count + leader views
sql/core/indexes.sql          pre-builds both indexes (make setup / demo-mode)
sql/core/drop_indexes.sql     drops them (make lab-mode)
sql/demo/walkthrough.sql      🎬 the demo script (~3 min, hint-based)
sql/lab/walkthrough.sql       🧪 the hands-on lab (~30–45 min, you run the DDL)
sql/lab/seed_satellites.sql   real satellite names (zero-app lab path)
sql/lab/backfill.sql          pure-SQL history backfill (zero-app lab path)
sql/lab/load.sql              pure-SQL live load: CALL lab_load(600);
app/ingest.py                 real positions via SGP4; --backfill + live mode
app/1_Dashboard.py            map, refresh latency, heat charts (Streamlit entry)
app/pages/2_Controls.py       buttons for setup/modes/refill/load; no terminal needed
app/pages/3_Connect.py          cluster connection info and shell reference
app/tle_snapshot.json         vendored orbital elements (offline fallback)
plans-viewer.html             pev2; paste EXPLAIN output, see the plan as boxes
```

`make help` lists the rest (cluster lifecycle, fault injection, log
collection, all inherited from
[yb-3node-demo](https://github.com/vickyharp/yb-3node-demo)).

## Troubleshooting

- **Node exits with code 137**: Docker ran out of memory; `make repair-node N=<n>`.
- **An index exists but plans ignore it**: an interrupted backfill left it
  invalid (`pg_index.indisvalid = false`). Run `make demo-mode`, or drop
  and recreate it yourself in the lab.
- **Dashboard says "cannot query telemetry"**: setup hasn't run (the
  Controls page offers both modes), or the cluster is down (`make show`).
- **Table grew huge from a long-running loader**: `make refill` (~2 min).
- **Live TLE refresh fails**: fine; the vendored snapshot is the data
  source. The API is decoration, never a dependency.
