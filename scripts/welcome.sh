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

print_setup_loading() {
  cat <<'EOF'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⏳ Loading demo data (~3–5 min) — lab mode, no secondary indexes yet

The devcontainer runs make setup-lab automatically on first boot.
Progress appears in the Codespace creation log and any terminal where
bootstrap is running.

When it finishes:
  make load + make dash
  script: sql/lab/walkthrough.sql

For demo indexes after load: make demo-mode (~2 min)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

print_setup_failed() {
  cat <<'EOF'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
❌ Auto data load failed

   make setup-lab     retry lab path
   make setup         or demo path (includes indexes)

   make show          cluster status
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
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
  cat <<'EOF'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⏳ YugabyteDB cluster is still starting (or not reachable)

   bash scripts/wait-for-cluster.sh
   make show
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

main() {
  local nodes rows indexes bootstrap_state

  nodes="$(mc_status_cluster_nodes)"
  if [ "$nodes" != "3" ]; then
    print_cluster_waiting
    return 0
  fi

  if mc_status_data_loaded; then
    rows="$(mc_status_telemetry_rows)"
    indexes="$(mc_status_secondary_indexes)"
    print_ready "$rows" "$indexes"
    return 0
  fi

  bootstrap_state="$(mc_status_bootstrap_state)"
  if mc_status_should_auto_bootstrap; then
    case "$bootstrap_state" in
      running)
        print_setup_loading
        return 0
        ;;
      failed)
        print_setup_failed
        return 0
        ;;
      *)
        print_setup_loading
        return 0
        ;;
    esac
  fi

  print_setup_manual
}

main "$@"
