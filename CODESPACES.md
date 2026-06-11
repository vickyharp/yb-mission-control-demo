# Mission Control on GitHub Codespaces

Your Codespace is getting ready with **demo mode** already in progress: a 3-node YugabyteDB cluster, ~3M rows of satellite telemetry, and both secondary indexes. On a prebuilt Codespace this is usually done when you attach. Otherwise it finishes in the background (often a few minutes on a 4-core machine, longer on 2-core).

Run `make welcome` anytime. If you see a row count and two indexes listed, you are ready.

## Run the demo

1. **`make load`** in one terminal (live writes, ~150/sec)
2. **`make dash`** in another (dashboard at http://localhost:8501)
3. Open **`sql/demo/walkthrough.sql`** and step through it

Codespaces forwards port **8501** automatically. Use the **Ports** tab or the forwarded URL.

Prefer buttons? After `make dash`, use the dashboard **Controls** page. Connection strings are on **Connect**.

## Switch to lab mode

Want to build the indexes yourself instead?

1. **`make lab-mode`** (drops both indexes; instant)
2. **`make load`** and **`make dash`**
3. Open **`sql/lab/walkthrough.sql`**

You can switch back anytime with **`make demo-mode`** (~2 min).

## Still setting up?

`make welcome` prints phase, elapsed time, and row count. These files update while setup runs:

- **`bootstrap-status.txt`** (opens automatically)
- **`bootstrap.log`**

If elapsed time and row counts keep moving, it is not stuck. Pick a **4-core / 8 GB+** machine type when you can; three Yugabyte nodes on a 2-core Codespace run slowly and may OOM (exit 137).

## Useful URLs

| Service | URL |
|---|---|
| Mission Control dashboard | http://localhost:8501 |
| yugabyted UI | http://localhost:15433 |
| YSQL | `ysqlsh -h yb-node1 -p 5433 -U yugabyte` |

## Troubleshooting

- **Cluster still starting:** `make show` or `bash scripts/wait-for-cluster.sh`
- **Setup taking a long time:** normal on small machines; watch `bootstrap.log`
- **Setup failed:** `make setup` to retry
- **Node exits with code 137:** use a larger machine type or `make repair-node N=<n>`
- **Wiped data:** `make clean` deletes cluster data; next start reruns setup

Cluster images pull from [ghcr.io/vickyharp/yb-3node-demo](https://github.com/vickyharp/yb-3node-demo) (a mirror of `yugabytedb/yugabyte:latest`).

More detail: [README.md](README.md). Prebuild maintainer steps: [docs/PREBUILD.md](docs/PREBUILD.md).
