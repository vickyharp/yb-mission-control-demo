#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=compose-lib.sh
source "$SCRIPT_DIR/compose-lib.sh"

YSQL_HOST="$("$SCRIPT_DIR/resolve-ysql-host.sh")"
TIMEOUT="${CLUSTER_WAIT_TIMEOUT:-600}"
INTERVAL="${CLUSTER_WAIT_INTERVAL:-5}"

print_ready_banner() {
  cat <<'EOF'
✅ Cluster ready — 3 nodes alive

   yugabyted UI → http://localhost:15433
   Master UI    → http://localhost:7000
   TServer UI   → http://localhost:9000
   Connect      → make connect
   Help         → make help
EOF
}

print_connection_info() {
  local nodes="${1:-?}"
  cat <<EOF

   yugabyted UI → http://localhost:15433
   Master UI    → http://localhost:7000
   TServer UI   → http://localhost:9000
   YSQL         → ysqlsh -h ${YSQL_HOST} -p 5433 -U yugabyte
   Connect      → make connect
   Help         → make help
EOF
  if [ "$nodes" != "3" ]; then
    echo ""
    echo "   Nodes visible: ${nodes}/3"
  fi
}

get_node_count() {
  local count=""
  if command -v ysqlsh >/dev/null 2>&1; then
    count="$(ysqlsh -h "$YSQL_HOST" -p 5433 -U yugabyte \
      -tAc "SELECT count(*) FROM yb_servers()" 2>/dev/null || true)"
  elif command -v psql >/dev/null 2>&1; then
    count="$(psql -h "$YSQL_HOST" -p 5433 -U yugabyte \
      -tAc "SELECT count(*) FROM yb_servers()" 2>/dev/null || true)"
  elif command -v docker >/dev/null 2>&1; then
    count="$(compose_cmd exec -T yb-node1 /home/yugabyte/bin/ysqlsh -h yb-node1 -p 5433 -U yugabyte \
      -tAc "SELECT count(*) FROM yb_servers()" 2>/dev/null || true)"
  fi
  if [[ "$count" =~ ^[0-9]+$ ]]; then
    printf '%s' "$count"
  fi
}

print_diagnostics() {
  echo ""
  echo "━━ Cluster diagnostics ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "YSQL host : $YSQL_HOST:5433"
  echo "Timeout   : ${TIMEOUT}s"
  echo ""

  if command -v docker >/dev/null 2>&1; then
    compose_resolve_project
    compose_context
    echo "Compose project: $COMPOSE_PROJECT_NAME"
    compose_cmd ps -a || true
    echo ""
  fi

  local count
  count="$(get_node_count || true)"
  if [ -n "$count" ]; then
    echo "yb_servers() count: $count (need 3)"
  else
    echo "yb_servers() count: unavailable"
    if command -v ysqlsh >/dev/null 2>&1; then
      echo ""
      ysqlsh -h "$YSQL_HOST" -p 5433 -U yugabyte -c "SELECT 1;" 2>&1 | head -5 || true
    fi
  fi

  echo ""
  echo "Try: make diagnose | bash scripts/compose.sh logs yb-node3 --tail 50"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

wait_for_cluster() {
  local elapsed=0 count=""

  echo "⏳ Waiting for 3 nodes via ${YSQL_HOST}:5433 (timeout ${TIMEOUT}s)..."

  while [ "$elapsed" -lt "$TIMEOUT" ]; do
    count="$(get_node_count || true)"
    if [ "$count" = "3" ]; then
      echo ""
      return 0
    fi

    if [ -n "$count" ]; then
      echo "   … ${count}/3 nodes in yb_servers() (${elapsed}s)"
    else
      echo "   … YSQL not reachable yet (${elapsed}s)"
    fi

    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
  done

  echo ""
  echo "❌ Timed out after ${TIMEOUT}s (last count: ${count:-unknown})"
  print_diagnostics
  return 1
}

main() {
  case "${1:-}" in
    --diagnose|-d)
      print_diagnostics
      return 0
      ;;
    --show|-s)
      local count=""
      count="$(get_node_count || true)"
      if [ "$count" = "3" ]; then
        print_ready_banner
      else
        echo "Cluster status: ${count:-unknown}/3 nodes visible"
        print_connection_info "${count:-?}"
      fi
      return 0
      ;;
  esac

  if ! wait_for_cluster; then
    return 1
  fi

  echo '⚙️  Configuring data placement (RF=3, fault_tolerance=zone)...'
  if command -v docker >/dev/null 2>&1; then
    compose_cmd exec -T yb-node1 /home/yugabyte/bin/yugabyted configure data_placement \
      --fault_tolerance=zone 2>/dev/null || true
  fi

  print_ready_banner
}

main "$@"
