#!/usr/bin/env bash
# Run docker compose against the correct project (root or .devcontainer).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=compose-lib.sh
source "$SCRIPT_DIR/compose-lib.sh"

require_docker
compose_cmd "$@"
