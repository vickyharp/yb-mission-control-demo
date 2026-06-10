#!/usr/bin/env bash
# Shared docker compose helpers — source from other scripts, do not execute directly.

compose_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(dirname "$compose_lib_dir")}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}"

compose_in_devcontainer() {
  [ -f "$REPO_ROOT/.devcontainer/docker-compose.yml" ] && \
    { command -v getent >/dev/null && getent hosts yb-node1 >/dev/null 2>&1 || \
      { command -v python3 >/dev/null && \
        python3 -c "import socket; socket.gethostbyname('yb-node1')" >/dev/null 2>&1; }; }
}

compose_context() {
  if compose_in_devcontainer; then
    COMPOSE_FILE="$REPO_ROOT/.devcontainer/docker-compose.yml"
    COMPOSE_DIR="$REPO_ROOT/.devcontainer"
  else
    COMPOSE_FILE="$REPO_ROOT/docker-compose.yml"
    COMPOSE_DIR="$REPO_ROOT"
  fi
}

# Devcontainer/Codespaces often starts compose under a different project name than
# the default directory basename. Detect the running project from container labels.
compose_resolve_project() {
  compose_context

  if [ -n "$COMPOSE_PROJECT_NAME" ]; then
    return 0
  fi

  local detected=""
  detected="$(docker ps \
    --filter 'label=com.docker.compose.service=yb-node1' \
    --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | head -1)"

  if [ -n "$detected" ]; then
    COMPOSE_PROJECT_NAME="$detected"
    return 0
  fi

  # Default baked into both compose files; used for fresh starts.
  COMPOSE_PROJECT_NAME="yb-mission-control-demo"
}

compose_cmd() {
  compose_resolve_project
  docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" --project-directory "$COMPOSE_DIR" "$@"
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    cat >&2 <<'EOF'
docker: command not found.

Inside the devcontainer/Codespaces, rebuild the container so the Docker CLI
and socket mount are available. Until then you can still use ysqlsh:

  ysqlsh -h yb-node1 -p 5433 -U yugabyte
EOF
    exit 1
  fi
}
