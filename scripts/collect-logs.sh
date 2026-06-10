#!/usr/bin/env bash
# Collect TServer and Master logs from all 3 nodes into a timestamped bundle.
# Usage: ./scripts/collect-logs.sh [optional note]
# Snapshots are saved under logs/ in the project root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=compose-lib.sh
source "$SCRIPT_DIR/compose-lib.sh"

require_docker

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
NOTE="${1:-}"
BUNDLE_NAME="bundle_${TIMESTAMP}${NOTE:+_${NOTE// /_}}"
BUNDLE_DIR="$PROJECT_DIR/logs/$BUNDLE_NAME"

mkdir -p "$BUNDLE_DIR"

echo "Collecting logs into: logs/$BUNDLE_NAME"

for n in 1 2 3; do
  NODE_DIR="$BUNDLE_DIR/node${n}"
  mkdir -p "$NODE_DIR/tserver" "$NODE_DIR/master"

  echo "  node${n}: TServer logs..."
  compose_cmd cp \
    "yb-node${n}:/root/var/data/yb-data/tserver/logs/." "$NODE_DIR/tserver/" 2>/dev/null \
    || echo "  node${n}: TServer logs unavailable (node down?)"

  echo "  node${n}: Master logs..."
  compose_cmd cp \
    "yb-node${n}:/root/var/data/yb-data/master/logs/." "$NODE_DIR/master/" 2>/dev/null \
    || echo "  node${n}: Master logs unavailable (node down?)"
done

echo "  Docker Compose log stream..."
compose_cmd logs yb-node1 yb-node2 yb-node3 > "$BUNDLE_DIR/docker-compose.log" 2>&1 \
  || echo "  Docker Compose log stream unavailable"

echo ""
echo "Done. Bundle saved to:"
echo "  $BUNDLE_DIR"
du -sh "$BUNDLE_DIR"
