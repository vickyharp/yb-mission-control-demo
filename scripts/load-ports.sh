#!/usr/bin/env bash
# Source this file to load port env vars from .env with defaults.
# Intended to be sourced, not executed directly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$REPO_ROOT/.env"

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a
  source "$ENV_FILE"
  set +a
fi

YB_MASTER_UI_PORT="${YB_MASTER_UI_PORT:-7000}"
YB_TSERVER_UI_PORT="${YB_TSERVER_UI_PORT:-9000}"
YB_YSQL_PORT="${YB_YSQL_PORT:-5433}"
YB_MASTER_RPC_PORT="${YB_MASTER_RPC_PORT:-7100}"
YB_TSERVER_RPC_PORT="${YB_TSERVER_RPC_PORT:-9100}"
YB_YB_UI_PORT="${YB_YB_UI_PORT:-15433}"
