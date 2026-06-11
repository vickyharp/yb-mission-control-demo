#!/usr/bin/env bash
# Shared cluster + demo-data probes. Source from welcome/bootstrap scripts.
# shellcheck shell=bash

_MC_STATUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT_DEFAULT="$(dirname "$_MC_STATUS_DIR")"
# shellcheck source=compose-lib.sh
source "$_MC_STATUS_DIR/compose-lib.sh"

MC_STATUS_BOOTSTRAP_STATUS="${MC_STATUS_BOOTSTRAP_STATUS:-/tmp/mission-control-bootstrap.status}"
MC_STATUS_BOOTSTRAP_LOCK="${MC_STATUS_BOOTSTRAP_LOCK:-/tmp/mission-control-bootstrap.lock}"
MC_STATUS_BOOTSTRAP_LOG="${MC_STATUS_BOOTSTRAP_LOG:-${_REPO_ROOT_DEFAULT}/bootstrap.log}"
MC_STATUS_ONELINER="${MC_STATUS_ONELINER:-${_REPO_ROOT_DEFAULT}/bootstrap-status.txt}"
MC_STATUS_DB="${MISSION_CONTROL_DB:-mission_control}"
MC_STATUS_TARGET_ROWS="${ROWS:-3000000}"
MC_STATUS_STARTED_AT="${MC_STATUS_STARTED_AT:-}"

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

mc_status_telemetry_tablets() {
  local count
  count="$(mc_status_run_ysql "$MC_STATUS_DB" \
    "SELECT count(*) FROM yb_tablet_metadata WHERE db_name = current_database() AND relname = 'telemetry'")"
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

mc_status_now_epoch() {
  date +%s
}

mc_status_read_field() {
  local key="$1"
  if [ -f "$MC_STATUS_BOOTSTRAP_STATUS" ]; then
    grep -m1 "^${key}=" "$MC_STATUS_BOOTSTRAP_STATUS" 2>/dev/null | cut -d= -f2- || true
  fi
}

mc_status_bootstrap_state() {
  mc_status_read_field "state"
}

mc_status_bootstrap_phase() {
  mc_status_read_field "phase"
}

mc_status_bootstrap_detail() {
  mc_status_read_field "detail"
}

mc_status_format_rows() {
  local rows="$1"
  if [[ "$rows" =~ ^[0-9]+$ ]] && [ "$rows" -ge 1000 ]; then
    printf '%s' "$(awk "BEGIN {printf \"%.1fM\", $rows/1000000}")"
  else
    printf '%s' "$rows"
  fi
}

mc_status_elapsed_human() {
  local started="${1:-}"
  local now elapsed mins
  if [ -z "$started" ] || ! [[ "$started" =~ ^[0-9]+$ ]]; then
    printf 'unknown'
    return
  fi
  now="$(mc_status_now_epoch)"
  elapsed=$((now - started))
  if [ "$elapsed" -lt 60 ]; then
    printf '%ds' "$elapsed"
  else
    mins=$((elapsed / 60))
    printf '%dm %ds' "$mins" "$((elapsed % 60))"
  fi
}

mc_status_write_oneliner() {
  local line="$1"
  printf '%s\n' "$line" > "$MC_STATUS_ONELINER"
}

mc_status_write_progress() {
  local state="$1"
  local phase="$2"
  local detail="$3"
  local nodes rows started updated now_epoch elapsed

  if [ -z "$MC_STATUS_STARTED_AT" ]; then
    MC_STATUS_STARTED_AT="$(mc_status_read_field "started_at")"
  fi
  if [ -z "$MC_STATUS_STARTED_AT" ] && [ "$state" = "running" ]; then
    MC_STATUS_STARTED_AT="$(mc_status_now_epoch)"
  fi

  now_epoch="$(mc_status_now_epoch)"
  nodes="$(mc_status_cluster_nodes)"
  rows="$(mc_status_telemetry_rows)"
  started="${MC_STATUS_STARTED_AT:-$now_epoch}"
  elapsed="$(mc_status_elapsed_human "$started")"

  cat > "$MC_STATUS_BOOTSTRAP_STATUS" <<EOF
state=${state}
phase=${phase}
detail=${detail}
started_at=${started}
updated_at=${now_epoch}
nodes=${nodes}
rows=${rows}
target_rows=${MC_STATUS_TARGET_ROWS}
EOF

  mc_status_write_oneliner "[$(date +%H:%M:%S)] ${phase} — ${detail} (${elapsed}, ${nodes}/3 nodes, $(mc_status_format_rows "$rows") rows)"
}

mc_status_refresh_progress() {
  local state phase detail started
  state="$(mc_status_bootstrap_state)"
  phase="$(mc_status_bootstrap_phase)"
  detail="$(mc_status_bootstrap_detail)"
  started="$(mc_status_read_field "started_at")"
  if [ -z "$state" ]; then
    return 0
  fi
  MC_STATUS_STARTED_AT="$started"
  mc_status_write_progress "$state" "$phase" "$detail"
}

mc_status_log_heartbeat() {
  local state phase detail rows nodes elapsed
  state="$(mc_status_bootstrap_state)"
  phase="$(mc_status_bootstrap_phase)"
  detail="$(mc_status_bootstrap_detail)"
  rows="$(mc_status_telemetry_rows)"
  nodes="$(mc_status_cluster_nodes)"
  elapsed="$(mc_status_elapsed_human "$(mc_status_read_field "started_at")")"
  printf '[%s] heartbeat: state=%s phase=%s | %s | %s/3 nodes | %s rows | %s\n' \
    "$(date +%H:%M:%S)" "$state" "$phase" "$detail" "$nodes" "$rows" "$elapsed"
}

mc_status_bootstrap_log_tail() {
  local n="${1:-8}"
  if [ -f "$MC_STATUS_BOOTSTRAP_LOG" ]; then
    tail -n "$n" "$MC_STATUS_BOOTSTRAP_LOG"
  fi
}

mc_status_set_bootstrap_state() {
  mc_status_write_progress "$1" "$(mc_status_bootstrap_phase)" "$(mc_status_bootstrap_detail)"
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
