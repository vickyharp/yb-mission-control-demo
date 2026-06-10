#!/usr/bin/env bash
set -euo pipefail

NODE=${1:?Usage: revive-node.sh <1|2|3>}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=compose-lib.sh
source "$SCRIPT_DIR/compose-lib.sh"

require_docker

echo "🟢 Starting yb-node${NODE}..."
compose_cmd start "yb-node${NODE}"
echo "   Node ${NODE} is rejoining the cluster and syncing its WAL."
