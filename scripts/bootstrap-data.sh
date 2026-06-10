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
  echo "   make setup-lab — schema + ~3M satellite rows, no secondary indexes"
  echo "   Demo indexes later: make demo-mode"
  echo ""
  make -C "$REPO_ROOT" setup-lab
}

main() {
  if ! mc_status_should_auto_bootstrap; then
    mc_status_set_bootstrap_state "skipped"
    return 0
  fi

  if mc_status_data_loaded; then
    mc_status_set_bootstrap_state "skipped"
    return 0
  fi

  exec 9>"$MC_STATUS_BOOTSTRAP_LOCK"
  if ! flock -n 9; then
    mc_status_set_bootstrap_state "running"
    echo "Demo data load already running (another process holds the lock)."
    return 0
  fi

  mc_status_set_bootstrap_state "running"

  if ! run_setup_lab; then
    mc_status_set_bootstrap_state "failed"
    echo ""
    echo "❌ Auto bootstrap failed. Run manually: make setup-lab"
    return 1
  fi

  mc_status_set_bootstrap_state "done"
  echo ""
  echo "✅ Lab data loaded. Next: make load + make dash"
  return 0
}

main "$@"
