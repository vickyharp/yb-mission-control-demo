#!/usr/bin/env bash
# Codespaces prebuild: cluster + demo-mode data captured in updateContentCommand snapshot.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=compose-lib.sh
source "$SCRIPT_DIR/compose-lib.sh"
# shellcheck source=mc-status.sh
source "$SCRIPT_DIR/mc-status.sh"

MARKER="$REPO_ROOT/.yb-data/.prebuild-done"

main() {
  if ! compose_in_devcontainer; then
    echo "prebuild-setup: skipped (not in devcontainer/Codespaces)"
    return 0
  fi

  require_docker
  mkdir -p "$REPO_ROOT/.yb-data/node1" "$REPO_ROOT/.yb-data/node2" "$REPO_ROOT/.yb-data/node3"

  echo "━━ Mission Control prebuild setup ━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "   cluster → wait → make setup (demo mode)"
  echo ""

  compose_cmd up -d

  if ! bash "$SCRIPT_DIR/wait-for-cluster.sh"; then
    echo "❌ prebuild-setup: cluster wait failed"
    return 1
  fi

  if mc_status_data_loaded; then
    local indexes
    indexes="$(mc_status_secondary_indexes)"
    echo "✅ prebuild-setup: data already present ($(mc_status_telemetry_rows) rows; indexes: ${indexes:-none})"
    date -Is > "$MARKER"
    return 0
  fi

  if ! make -C "$REPO_ROOT" setup; then
    echo "❌ prebuild-setup: make setup failed"
    return 1
  fi

  date -Is > "$MARKER"
  echo "✅ prebuild-setup: demo mode ready ($(mc_status_telemetry_rows) rows)"
  return 0
}

main "$@"
