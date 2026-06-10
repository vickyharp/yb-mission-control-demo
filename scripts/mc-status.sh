#!/usr/bin/env bash
# Shared cluster + demo-data probes. Source from welcome/bootstrap scripts.
# shellcheck shell=bash

_MC_STATUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=compose-lib.sh
source "$_MC_STATUS_DIR/compose-lib.sh"

MC_STATUS_BOOTSTRAP_STATUS="${MC_STATUS_BOOTSTRAP_STATUS:-/tmp/mission-control-bootstrap.status}"
MC_STATUS_BOOTSTRAP_LOCK="${MC_STATUS_BOOTSTRAP_LOCK:-/tmp/mission-control-bootstrap.lock}"
MC_STATUS_DB="${MISSION_CONTROL_DB:-mission_control}"

mc_status_ysql_host() {
  if [ -z "${_MC_STATUS_YSQL_HOST:-}" ]; then
    _MC_STATUS_YSQL_HOST="$("$_MC_STATUS_DIR/resolve-ysql-host.sh")"
  fi
  printf '%s' "$_MC_STATUS_YSQL_HOST"
}

mc_status_run_ysql() {
  local db="${1:-}"
  local sql="${2:-}"
  local host
  host="$(mc_status_ysql_host)"
  if command -v ysqlsh >/dev/null 2>&1; then
    if [ -n "$db" ]; then
      ysqlsh -h "$host" -p 5433 -U yugabyte -d "$db" -tAc "$sql" 2>/dev/null || true
    else
      ysqlsh -h "$host" -p 5433 -U yugabyte -tAc "$sql" 2>/dev/null || true
    fi
  elif command -v docker >/dev/null 2>&1; then
    compose_resolve_project
    if [ -n "$db" ]; then
      compose_cmd exec -T yb-node1 /home/yugabyte/bin/ysqlsh -h yb-node1 -p 5433 -U yugabyte -d "$db" \
        -tAc "$sql" 2>/dev/null || true
    else
      compose_cmd exec -T yb-node1 /home/yugabyte/bin/ysqlsh -h yb-node1 -p 5433 -U yugabyte \
        -tAc "$sql" 2>/dev/null || true
    fi
  fi
}

mc_status_cluster_nodes() {
  local count
  count="$(mc_status_run_ysql "" "SELECT count(*) FROM yb_servers()")"
  if [[ "$count" =~ ^[0-9]+$ ]]; then
    printf '%s' "$count"
  else
    printf '0'
  fi
}

mc_status_db_exists() {
  local hit
  hit="$(mc_status_run_ysql "" "SELECT 1 FROM pg_database WHERE datname='${MC_STATUS_DB}'")"
  [ "$hit" = "1" ]
}

mc_status_telemetry_rows() {
  local count
  count="$(mc_status_run_ysql "$MC_STATUS_DB" "SELECT count(*) FROM telemetry")"
  if [[ "$count" =~ ^[0-9]+$ ]]; then
    printf '%s' "$count"
  else
    printf '0'
  fi
}

mc_status_secondary_indexes() {
  mc_status_run_ysql "$MC_STATUS_DB" \
    "SELECT coalesce(string_agg(indexrelid::regclass::text, ', ' ORDER BY indexrelid::regclass::text), '')
     FROM pg_index
     WHERE indrelid = 'telemetry'::regclass
       AND indexrelid::regclass::text NOT LIKE '%pkey'"
}

mc_status_bootstrap_state() {
  if [ -f "$MC_STATUS_BOOTSTRAP_STATUS" ]; then
    tr -d '[:space:]' < "$MC_STATUS_BOOTSTRAP_STATUS"
  fi
}

mc_status_set_bootstrap_state() {
  printf '%s\n' "$1" > "$MC_STATUS_BOOTSTRAP_STATUS"
}

# Devcontainer / Codespaces: cluster runs on the compose network inside this container.
mc_status_should_auto_bootstrap() {
  if [ "${MISSION_CONTROL_AUTO_BOOTSTRAP:-}" = "1" ]; then
    return 0
  fi
  if compose_in_devcontainer; then
    return 0
  fi
  return 1
}

mc_status_data_loaded() {
  mc_status_db_exists && [ "$(mc_status_telemetry_rows)" != "0" ]
}
