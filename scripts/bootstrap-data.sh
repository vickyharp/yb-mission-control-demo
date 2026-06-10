#!/usr/bin/env bash
# Load lab demo data once in devcontainer/Codespaces. Idempotent; safe on every start.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=mc-status.sh
source "$SCRIPT_DIR/mc-status.sh"

run_setup_lab() {
  echo ""
  echo "━━ Loading demo data (lab mode, ~3–5 min) ━━━━━━━━━━━━━━━━━━━"
  echo "   schema → views → backfill → ANALYZE"
  echo "   Demo indexes later: make demo-mode"
  echo ""

  mc_status_write_progress "running" "venv" "Python dependencies"
  make -C "$REPO_ROOT" venv

  mc_status_write_progress "running" "database" "creating mission_control if needed"
  make -C "$REPO_ROOT" db

  mc_status_write_progress "running" "schema" "tables and database settings"
  make -C "$REPO_ROOT" setup-lab-schema

  mc_status_write_progress "running" "views" "observation views"
  make -C "$REPO_ROOT" setup-lab-views

  mc_status_write_progress "running" "backfill" "starting ~3M row load (slow step)"
  make -C "$REPO_ROOT" setup-lab-backfill

  mc_status_write_progress "running" "analyze" "updating table statistics"
  make -C "$REPO_ROOT" setup-lab-analyze

  return 0
}

main() {
  if ! mc_status_should_auto_bootstrap; then
    mc_status_write_progress "skipped" "bootstrap" "not a devcontainer/Codespaces environment"
    return 0
  fi

  if mc_status_data_loaded; then
    mc_status_write_progress "skipped" "bootstrap" "$(mc_status_telemetry_rows) rows already loaded"
    return 0
  fi

  exec 9>"$MC_STATUS_BOOTSTRAP_LOCK"
  if ! flock -n 9; then
    mc_status_write_progress "running" "bootstrap" "another process is loading data"
    echo "Demo data load already running (another process holds the lock)."
    return 0
  fi

  mc_status_write_progress "running" "bootstrap" "starting lab setup"

  if ! run_setup_lab; then
    mc_status_write_progress "failed" "bootstrap" "setup-lab failed — see bootstrap.log"
    echo ""
    echo "❌ Auto bootstrap failed. Run manually: make setup-lab"
    return 1
  fi

  return 0
}

main "$@"
