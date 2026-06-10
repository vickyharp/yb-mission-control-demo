#!/usr/bin/env bash
# Print devcontainer / Codespaces status and the next step. Safe on every attach.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mc-status.sh
source "$SCRIPT_DIR/mc-status.sh"

print_setup_manual() {
  cat <<'EOF'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🛰️  Mission Control — cluster is up, demo data is NOT loaded yet

Pick one:

  🎬 Demo (~3 min story, indexes pre-built)
     make setup
     then: make load    (terminal 1)
           make dash    (terminal 2)
     script: sql/demo/walkthrough.sql

  🧪 Lab (~30 min, you run the DDL)
     make setup-lab
     then: make load + make dash
     script: sql/lab/walkthrough.sql

No terminal? After setup, open the dashboard (make dash) and use Controls.
See CODESPACES.md (Codespaces) or README.md (local Docker).
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

print_progress_footer() {
  cat <<'EOF'

   Open bootstrap.log in the editor for the full post-start log.
   make welcome   refresh this banner
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

print_setup_loading() {
  local state="$1"
  local phase="$2"
  local detail="$3"
  local nodes="$4"
  local rows="$5"
  local target="$6"
  local elapsed="$7"
  local pct=""

  if [[ "$rows" =~ ^[0-9]+$ ]] && [[ "$target" =~ ^[0-9]+$ ]] && [ "$target" -gt 0 ] \
     && [ "$rows" -gt 0 ]; then
    pct="$(awk "BEGIN {printf \"%.0f%% of target\", ($rows/$target)*100}")"
  fi

  cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⏳ Post-start still running — not stuck if this line updates

   Phase:    ${phase}
   Detail:   ${detail}
   Elapsed:  ${elapsed}
   Cluster:  ${nodes}/3 nodes
   Rows:     $(mc_status_format_rows "$rows") telemetry rows${pct:+ ($pct)}
EOF
  if [ -f "$MC_STATUS_ONELINER" ]; then
    echo "   Status:   $(cat "$MC_STATUS_ONELINER")"
  fi
  if [ -f "$MC_STATUS_BOOTSTRAP_LOG" ]; then
    echo ""
    echo "   Recent log:"
    mc_status_bootstrap_log_tail 5 | sed 's/^/     /'
  fi
  print_progress_footer
}

print_setup_failed() {
  local detail="${1:-see bootstrap.log}"
  cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
❌ Auto data load failed — ${detail}

   make setup-lab     retry lab path
   make setup         or demo path (includes indexes)
   make show          cluster status
EOF
  if [ -f "$MC_STATUS_BOOTSTRAP_LOG" ]; then
    echo ""
    echo "   Recent log:"
    mc_status_bootstrap_log_tail 8 | sed 's/^/     /'
  fi
  print_progress_footer
}

print_ready() {
  local rows="$1"
  local indexes="$2"
  cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Mission Control ready — ${rows} telemetry rows loaded
EOF
  if [ -n "$indexes" ]; then
    echo "   Indexes: ${indexes}"
  else
    echo "   Mode: lab (no secondary indexes yet; make demo-mode for demo)"
  fi
  cat <<'EOF'

   make load     live writes (~150/sec; keep running)
   make dash     dashboard at http://localhost:8501
   make show     cluster URLs and status
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

print_cluster_waiting() {
  local state phase detail elapsed nodes
  state="$(mc_status_bootstrap_state)"
  phase="$(mc_status_bootstrap_phase)"
  detail="$(mc_status_bootstrap_detail)"
  elapsed="$(mc_status_elapsed_human "$(mc_status_read_field "started_at")")"
  nodes="$(mc_status_cluster_nodes)"

  if [ "$state" = "running" ] && [ "$phase" = "cluster" ]; then
    print_setup_loading "$state" "$phase" "$detail" "$nodes" "0" "$MC_STATUS_TARGET_ROWS" "$elapsed"
    return
  fi

  cat <<'EOF'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⏳ YugabyteDB cluster is still starting (or not reachable)

   bash scripts/wait-for-cluster.sh
   make show
EOF
  if [ -f "$MC_STATUS_BOOTSTRAP_LOG" ]; then
    echo ""
    echo "   Recent log:"
    mc_status_bootstrap_log_tail 5 | sed 's/^/     /'
  fi
  print_progress_footer
}

main() {
  local nodes rows indexes state phase detail target elapsed started

  nodes="$(mc_status_cluster_nodes)"
  state="$(mc_status_bootstrap_state)"
  phase="$(mc_status_bootstrap_phase)"
  detail="$(mc_status_bootstrap_detail)"
  target="$(mc_status_read_field "target_rows")"
  started="$(mc_status_read_field "started_at")"
  elapsed="$(mc_status_elapsed_human "$started")"
  rows="$(mc_status_telemetry_rows)"

  if [ "$nodes" != "3" ]; then
    print_cluster_waiting
    return 0
  fi

  if mc_status_data_loaded; then
    indexes="$(mc_status_secondary_indexes)"
    print_ready "$rows" "$indexes"
    return 0
  fi

  if [ "$state" = "failed" ]; then
    print_setup_failed "$detail"
    return 0
  fi

  if mc_status_should_auto_bootstrap; then
    if [ -z "$state" ]; then
      phase="starting"
      detail="post-start has not written status yet (very early boot)"
    fi
    print_setup_loading "$state" "$phase" "$detail" "$nodes" "$rows" "${target:-$MC_STATUS_TARGET_ROWS}" "$elapsed"
    return 0
  fi

  print_setup_manual
}

main "$@"
