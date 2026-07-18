#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_DIR="$ROOT_DIR/.run/webapp"
DATA_ROOT="$(python3 "$ROOT_DIR/scripts/resolve_data_root.py" data-root)"
LOG_DIR="$DATA_ROOT/logs/webapp"

status_by_pidfile() {
  local name="$1"
  local pid_file="$2"
  if [ ! -f "$pid_file" ]; then
    echo "[status_webapp] $name: stopped (no pid file)"
    return 0
  fi

  local pid
  pid="$(cat "$pid_file")"
  if kill -0 "$pid" 2>/dev/null; then
    echo "[status_webapp] $name: running pid=$pid"
  else
    echo "[status_webapp] $name: stale pid file ($pid)"
  fi
}

status_by_pidfile "web" "$RUN_DIR/web.pid"
status_by_pidfile "coordinator" "$RUN_DIR/coordinator.pid"
status_by_pidfile "status-collector" "$RUN_DIR/status-collector.pid"
status_by_pidfile "worker(legacy)" "$RUN_DIR/worker.pid"

echo "[status_webapp] logs: $LOG_DIR"
