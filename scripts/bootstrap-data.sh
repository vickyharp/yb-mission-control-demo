#!/usr/bin/env bash
# Load demo data once in devcontainer/Codespaces. Idempotent; safe on every start.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=mc-status.sh
source "$SCRIPT_DIR/mc-status.sh"

run_setup_demo() {
  echo ""
  echo "━━ Loading demo data (demo mode) ━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "   schema → views → backfill → indexes → ANALYZE"
  echo ""

  mc_status_write_progress "running" "setup" "make setup (demo mode, ~5-15 min on small machines)"
  make -C "$REPO_ROOT" setup
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

  mc_status_write_progress "running" "bootstrap" "starting demo setup"

  if ! run_setup_demo; then
    mc_status_write_progress "failed" "bootstrap" "demo setup failed — see bootstrap.log"
    echo ""
    echo "❌ Auto bootstrap failed. Run manually: make setup"
    return 1
  fi

  return 0
}

main "$@"
