#!/usr/bin/env bash
# Devcontainer postStart: cluster wait + lab bootstrap, with visible progress.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=mc-status.sh
source "$SCRIPT_DIR/mc-status.sh"

MC_POSTSTART_ACTIVE="${MC_POSTSTART_ACTIVE:-/tmp/mission-control-poststart.active}"
HEARTBEAT_PID=""

setup_logging() {
  MC_STATUS_BOOTSTRAP_LOG="$REPO_ROOT/bootstrap.log"
  : > "$MC_STATUS_BOOTSTRAP_LOG"
  exec > >(tee -a "$MC_STATUS_BOOTSTRAP_LOG") 2>&1
  echo "Mission Control post-start — $(date -Is)"
  echo "Live log: bootstrap.log (open in editor) | status: make welcome"
  echo ""
}

start_heartbeat() {
  touch "$MC_POSTSTART_ACTIVE"
  (
    while [ -f "$MC_POSTSTART_ACTIVE" ]; do
      mc_status_refresh_progress
      mc_status_log_heartbeat
      sleep 15
    done
  ) &
  HEARTBEAT_PID=$!
}

stop_heartbeat() {
  rm -f "$MC_POSTSTART_ACTIVE"
  if [ -n "$HEARTBEAT_PID" ]; then
    wait "$HEARTBEAT_PID" 2>/dev/null || true
    HEARTBEAT_PID=""
  fi
}

main() {
  setup_logging
  mc_status_write_progress "running" "post-start" "starting"
  start_heartbeat

  mc_status_write_progress "running" "cluster" "waiting for 3 nodes"
  if ! bash "$SCRIPT_DIR/wait-for-cluster.sh"; then
    stop_heartbeat
    mc_status_write_progress "failed" "cluster" "timed out or unreachable"
    return 1
  fi

  mc_status_write_progress "running" "cluster" "3 nodes ready"
  if ! bash "$SCRIPT_DIR/bootstrap-data.sh"; then
    stop_heartbeat
    return 1
  fi

  stop_heartbeat
  if mc_status_data_loaded; then
    mc_status_write_progress "done" "ready" "$(mc_status_telemetry_rows) rows loaded"
  else
    mc_status_write_progress "skipped" "bootstrap" "no data load needed"
  fi

  echo ""
  echo "✅ post-start finished — run make welcome for status"
  return 0
}

main "$@"
