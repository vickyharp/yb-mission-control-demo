#!/usr/bin/env bash
# Print the YSQL host to use from the current environment.
# Inside the devcontainer/Codespaces, yb-node1 is reachable on the compose network.
# On the Docker host (Mac/Linux), published ports are on localhost.

set -euo pipefail

if [ -n "${YSQL_HOST:-}" ]; then
  printf '%s\n' "$YSQL_HOST"
  exit 0
fi

if command -v getent >/dev/null 2>&1 && getent hosts yb-node1 >/dev/null 2>&1; then
  printf 'yb-node1\n'
  exit 0
fi

if command -v python3 >/dev/null 2>&1 && \
   python3 -c "import socket; socket.gethostbyname('yb-node1')" >/dev/null 2>&1; then
  printf 'yb-node1\n'
  exit 0
fi

printf 'localhost\n'
