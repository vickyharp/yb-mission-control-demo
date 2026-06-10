# Mission Control on GitHub Codespaces

You opened a Codespace. Here is what already happened and what you do next.

## What the Codespace did for you

On first boot (and on every start until data exists), the environment:

1. Starts the **3-node YugabyteDB cluster** (first boot can take a few minutes).
2. Waits until all three nodes answer on YSQL.
3. Runs **`make setup-lab` automatically** if `telemetry` is still empty (~3M rows, no secondary indexes).

That backfill is the slow part. You may see "Creating codespace" or a loading banner in the terminal while it runs. `make welcome` tells you whether load is still running or finished.

Demo mode indexes are **not** pre-built. Run `make demo-mode` (~2 min) when you want the presenter path with both indexes.

## Check where you are

```bash
make welcome     # status banner (also prints on attach)
make show        # cluster URLs and node count
```

## When data load finishes

### Step 1 — Start live writes and the dashboard

In **two terminals**:

```bash
make load    # terminal 1: ~150 inserts/sec until you stop it
make dash    # terminal 2: Streamlit on port 8501
```

Codespaces forwards port **8501** automatically. Open the **Ports** tab or the forwarded URL for the dashboard.

### Step 2 — Follow the walkthrough

| Path | Script | Extra step |
|---|---|---|
| Lab (default here) | `sql/lab/walkthrough.sql` | none |
| Demo | `sql/demo/walkthrough.sql` | `make demo-mode` first |

Open the script in the editor or connect with `make connect`.

The dashboard **Connect** page lists connection strings. **Controls** can run the same `make` targets without a terminal.

## Useful URLs (after the cluster is up)

| Service | URL |
|---|---|
| Mission Control dashboard | http://localhost:8501 |
| yugabyted UI | http://localhost:15433 |
| YSQL | `ysqlsh -h yb-node1 -p 5433 -U yugabyte` |

## Troubleshooting

- **Cluster still starting:** `bash scripts/wait-for-cluster.sh` or `make show`
- **"Loading demo data" for a long time:** check the Codespace creation log; backfill can take ~5 min
- **Auto load failed:** `make setup-lab` or `make bootstrap` to retry
- **Dashboard cannot query telemetry:** load still running, or bootstrap failed; `make welcome`
- **Node exits with code 137:** out of memory; `make repair-node N=<n>`

More detail lives in [README.md](README.md).
