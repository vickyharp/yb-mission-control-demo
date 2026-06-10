#!/usr/bin/env bash
# Wipe a node's data volume and recreate it (fixes OOM 137 / corrupt bootstrap).
set -euo pipefail

NODE=${1:?Usage: repair-node.sh <1|2|3>}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=compose-lib.sh
source "$SCRIPT_DIR/compose-lib.sh"

require_docker

echo "🔧 Repairing yb-node${NODE} (stop → remove container → delete volume → recreate)..."

compose_cmd stop "yb-node${NODE}" 2>/dev/null || true
compose_cmd rm -f "yb-node${NODE}" 2>/dev/null || true

VOLUME="$(docker volume ls -q | grep "yb-node${NODE}-data" | head -1 || true)"
if [ -n "$VOLUME" ]; then
  echo "   Removing volume: $VOLUME"
  docker volume rm "$VOLUME"
else
  echo "   No data volume found for node ${NODE} (already clean)"
fi

compose_cmd up -d "yb-node${NODE}"

echo ""
echo "   Node ${NODE} is rejoining. Wait for the cluster with:"
echo "     make wait"
