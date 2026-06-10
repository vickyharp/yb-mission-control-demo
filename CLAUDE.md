# Mission Control: agent guide

A YugabyteDB bucket index demo. One query (`SELECT … FROM telemetry ORDER BY
ts DESC LIMIT 500`) goes through three states: hash PK only (seq scan + sort,
~1 s on 3M rows), range index on ts (fast reads, hot newest tablet under
live write load), bucket index `((yb_hash_code(ts) % 6) ASC, ts DESC)` (fast
reads via 6 merge streams AND spread writes). The business skin is mission
control for ~500 real satellites; ingest.py propagates genuine TLE orbital
elements with sgp4, and the dashboard map shows the actual ISS, HST, and CSS
with ground trails.

Read the README first; it is accurate and explains demo mode vs lab mode.
This file is for what the README doesn't say: invariants, YB gotchas, and
where the work stands.

## Deadlines and deliverables

- Demo session around 2026-07-10. Owner: Vicky Harp.
- Still to do: push to GitHub, one real Codespaces run end to end, then a
  2–3 minute screen recording of the presenter path for Slack (Amiram's ask).
- Narrative structure follows manager feedback: story first, performance
  today, intermediate fix, final fix, the trade-off stated honestly, then
  where else the pattern applies. Don't reorder it.

## Architecture in one breath

3-node YugabyteDB cluster (docker-compose, devcontainer for Codespaces,
copied from yb-3node-demo) → `mission_control` database → `telemetry` table
(hash PK, 6 tablets, ~3M rows backfilled) → two pre-buildable secondary
indexes → Streamlit multipage app (`app/1_Dashboard.py`, plus Controls and
Connect pages) → numbered SQL walkthroughs in `sql/demo/` (hint-based
presenter script) and `sql/lab/` (real-DDL learner script, fully runnable
with zero app code). `make help` lists every command.

## Invariants. Break these and the demo lies or falls over.

1. **Mode is which indexes exist.** No stored mode flag anywhere. `make
   demo-mode` builds both indexes, `make lab-mode` drops both. The
   dashboard's read-path radio and heat panels adapt to the catalog.
2. **One query, byte-identical everywhere.** The dashboard's TELEMETRY_SQL,
   the timed latency metric, the map feed, the glow membership (first 100
   rows), and every walkthrough EXPLAIN are the same `LIMIT 500` query, only
   the pg_hint_plan prefix varies. Never add a second query shape to the
   page (we removed a DISTINCT ON one for exactly this reason). The heat
   sample query is the one allowed exception and is labeled "not part of
   the demo".
3. **The derived-SAOP settings are load-bearing.** Without
   `yb_enable_derived_equalities`, `yb_enable_derived_saops`, and
   `yb_max_saop_merge_streams` the bucket index full-scans instead of
   merge-streaming. `sql/core/01_schema.sql` applies them (DO block with
   current_database() plus session SETs). Keep them there, not in the
   Makefile.
4. **Never run CREATE INDEX in front of an audience.** Backfill takes
   minutes and an interrupted one leaves `pg_index.indisvalid = false`,
   which the planner ignores silently. Presenter path switches read paths
   with hints against pre-built indexes; only the lab does real DDL.
5. **Views reference relations by name string, never `::regclass`
   literals.** Regclass creates a dependency that makes DROP INDEX fail,
   and breaks view creation when the index doesn't exist yet (lab mode).
6. **Timestamps must spread inside every batch.** Identical ts values hash
   to one bucket and make the bucket index's write distribution chunky.
   Both ingest.py and sql/lab/backfill.sql stagger per-row timestamps.
7. **Loaders survive DDL races.** Index backfill causes transient
   "schema version mismatch" SerializationFailures even with object locking
   on. ingest.py drops the batch and continues; lab_load() does the same in
   a plpgsql exception block (COMMIT must sit outside the handled block).
8. **The map's `showland` stays off.** Unfilled continents render as the
   page background (white on light themes). Every land fill we tried looked
   worse. Same story for the palette: plotly defaults, leave them.
9. **Reruns must not overlap.** `.streamlit/config.toml` sets
   `runner.fastReruns = false`, and the autorefresh interval is floored at
   1.5x measured query latency. Without both, a seq-scan-state query slower
   than the refresh interval ghosts duplicate widgets.
10. **Nothing rots.** Backfill is relative to now(); range-index split
    points are generated relative to today (format() + copy-paste in the
    lab, \gexec in core/indexes.sql). Keep it that way; hardcoded dates
    killed two predecessor demos.

## YB gotchas already paid for

- No multi-object DROP (`DROP VIEW a, b` fails). One statement each.
- CREATE INDEX can't run inside DO blocks or transactions; that's why
  split-point DDL is generated as text to copy-paste or piped via ysqlsh.
- pg_hint_plan hints don't reach scans inside subqueries pulled up into
  joins. Keep hinted queries join-free (satellite names join client-side).
- Record-returning SQL functions don't inline; per-row calls were 50x
  slower in the pure-SQL backfill, so the math is inlined there while
  lab/load.sql (150 rows/sec) uses the lab_position() function.
- COMMIT inside CALL works; the pure-SQL loaders rely on it.
- `yb_tablet_metadata` (pg_catalog) has hash ranges + leader per tablet;
  range-tablet identity comes from `yb_local_tablets()` ordered by
  partition_key_start. The `range_split_points` table records boundaries
  at index creation because the catalog won't give them back readably.
- Cluster flags: object locking + ysql_yb_ddl_transaction_block_enabled are
  set in both compose files; the flags require each other or the tserver
  crashes at boot.
- Docker node exits 137 = OOM; `make repair-node N=<n>`.

## Operational notes

- The table grows ~540k rows/hour while `make load` runs. The seq-scan
  state slows proportionally and the numbers drift off-script. `make
  refill` (TRUNCATE + reload, ~2 min, indexes survive) before presenting;
  also `make demo-mode` if the indexes are weeks old. As of the last
  session the table sat at 6.7M rows and needs a refill.
- Local dev: cluster project name is yb-mission-control-demo; helper
  scripts auto-detect it from running containers. Vicky has no native
  ysqlsh; the Makefile falls back to docker exec automatically.
- Streamlit and the loader are usually started by hand or from the
  Controls page (pidfile /tmp/mission-control-load.pid).
- The TLE API is decoration, never a dependency: app/tle_snapshot.json is
  the data source; --refresh-tle is best-effort.

## Writing style for user-facing text

User-facing text means the README, walkthrough SQL comments, dashboard and
page strings, and make help text. No "AI-forward" tone. Write like a
native, conversational human.

1. NO BUZZWORDS. Never: delve, tapestry, moreover, utilize, revolutionize,
   game-changer, unlock, dive deep.
2. NO METANARRATIVE. Don't announce what the writing will do ("Here is a
   guide"). Saying what the described actions do is fine ("This demo will
   show you…").
3. AVOID THE "NOT X, BUT Y" PATTERN. Make affirmative statements.
4. UNEVEN PARAGRAPHS. Vary paragraph lengths.
5. CASUAL BUT DIRECT. Plain English, no corporate hype.
6. AVOID EM DASHES (—). Use commas, periods, or semicolons. (The lone "—"
   glyph as an empty-metric placeholder in the dashboard is fine; that's UI
   convention, not prose.)
7. NO DEAD-EVALUATOR FILLER ("highlighting its importance", "paving the
   way for"). Say the thing.
8. DON'T OVERUSE THE RULE OF THREE. Repeated triads read as formula;
   consider two or four, or no list.
9. WATCH SUBORDINATE CLAUSES. "which means/which is" clauses usually want
   to be their own sentence. Reaching for an em dash means write a period.
10. NO "it's not just x, it's y" FRAMING, even in conversation.
11. RE-READ FOR LLM TELLS and do a second pass.
