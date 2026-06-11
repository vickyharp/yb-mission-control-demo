#!/usr/bin/env bash
# Stop the background load generator if Controls (or make load) started it.
set -euo pipefail

PIDFILE="/tmp/mission-control-load.pid"

if [ ! -f "$PIDFILE" ]; then
  exit 0
fi

pid="$(cat "$PIDFILE" 2>/dev/null || true)"
if [ -z "$pid" ]; then
  rm -f "$PIDFILE"
  exit 0
fi

if kill -0 "$pid" 2>/dev/null; then
  echo "Stopping live load (pid ${pid}) before setup/refill…"
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  kill -9 "$pid" 2>/dev/null || true
fi

rm -f "$PIDFILE"
