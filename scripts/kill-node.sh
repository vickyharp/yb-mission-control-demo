#!/usr/bin/env bash
set -euo pipefail

NODE=${1:?Usage: kill-node.sh <1|2|3>}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=compose-lib.sh
source "$SCRIPT_DIR/compose-lib.sh"

require_docker

echo "🔴 Stopping yb-node${NODE}..."
compose_cmd stop "yb-node${NODE}"
echo "   Node ${NODE} is down. Cluster has 2/3 nodes alive (quorum maintained)."
