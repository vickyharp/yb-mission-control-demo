#!/usr/bin/env bash
# Post-prebuild / post-bootstrap sanity check for Codespaces.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mc-status.sh
source "$SCRIPT_DIR/mc-status.sh"

TARGET_ROWS="${ROWS:-1000000}"
MIN_ROWS=$((TARGET_ROWS * 90 / 100))
ROWS="$(mc_status_telemetry_rows)"
TABLETS="$(mc_status_telemetry_tablets)"
INDEXES="$(mc_status_secondary_indexes)"
NODES="$(mc_status_cluster_nodes)"
FAIL=0

echo "Mission Control setup verification"
echo "  cluster nodes: ${NODES}/3"
echo "  telemetry tablets: ${TABLETS} (expect 6)"
echo "  telemetry rows: ${ROWS} (expect >= ${MIN_ROWS})"
echo "  secondary indexes: ${INDEXES:-none}"

if [ "$NODES" != "3" ]; then
  echo "FAIL: expected 3 cluster nodes"
  FAIL=1
fi

if [ "$TABLETS" != "6" ]; then
  echo "FAIL: telemetry has ${TABLETS} tablets (expected 6; re-run make setup)"
  FAIL=1
fi

if ! [[ "$ROWS" =~ ^[0-9]+$ ]] || [ "$ROWS" -lt "$MIN_ROWS" ]; then
  echo "FAIL: row count below ${MIN_ROWS}"
  FAIL=1
fi

if [ -z "$INDEXES" ]; then
  echo "FAIL: no secondary indexes (expected telemetry_by_time and telemetry_by_bucket)"
  FAIL=1
elif ! echo "$INDEXES" | grep -q 'telemetry_by_time' || ! echo "$INDEXES" | grep -q 'telemetry_by_bucket'; then
  echo "FAIL: missing expected index names"
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "OK: demo mode ready"
  exit 0
fi

echo ""
echo "Retry: make setup   Status: make welcome"
exit 1
