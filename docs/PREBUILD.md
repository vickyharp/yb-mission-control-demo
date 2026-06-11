# Codespaces prebuild setup (maintainers)

Mission Control bakes demo-mode data into Codespaces prebuilds via `updateContentCommand` in [`.devcontainer/devcontainer.json`](../.devcontainer/devcontainer.json). YugabyteDB node data lives in gitignored [`.yb-data/`](../.yb-data/) bind mounts so the snapshot captures it.

## Enable prebuilds (one-time, repo Settings)

1. Open **https://github.com/vickyharp/yb-mission-control-demo/settings/codespaces**
2. **Prebuild configurations** → **Set up prebuild**
3. Branch: **main**
4. Dev container config: **`.devcontainer/devcontainer.json`**
5. Triggers:
   - **Scheduled:** monthly (e.g. 1st of the month, morning UTC)
   - **On configuration change** (picks up `devcontainer.json` edits)
   - Do **not** use "Every push" alone (rebuilds ~3M rows + indexes constantly)
6. Regions: **one region** (your primary, e.g. US West)
7. Template history: **2**
8. Machine type: **4-core minimum** if selectable

Prebuild workflow runs `scripts/prebuild-setup.sh` (cluster + `make setup`). First run may take 15-30 minutes.

## GHCR image dependency

Codespaces pull YugabyteDB from `ghcr.io/vickyharp/yb-3node-demo:latest`, mirrored weekly in [yb-3node-demo](https://github.com/vickyharp/yb-3node-demo). The package must stay **public** ([package settings](https://github.com/users/vickyharp/packages/container/yb-3node-demo/settings)).

Local Docker on the host still uses `yugabytedb/yugabyte:latest` from Docker Hub.

## Verify after prebuild completes

1. Create a codespace from **main**; confirm **Prebuild ready** on the machine picker
2. After attach, `make welcome` should show ~3M rows and both secondary indexes without waiting for backfill
3. `make verify-setup` should print `OK: demo mode ready`
4. `make load` + `make dash`; open `sql/demo/walkthrough.sql`
5. Lab path: `make lab-mode`, then `sql/lab/walkthrough.sql`

## Monthly refresh and skew

Scheduled prebuilds keep range-index split points (`now()`-relative in `sql/core/indexes.sql`) and row counts on-script. Live `make load` still grows the table in long-running codespaces; run `make refill` before presenting if the seq-scan numbers have drifted.

## Manual prebuild trigger

Push a change to `.devcontainer/devcontainer.json`, or re-run the prebuild workflow from the Codespaces settings page.
