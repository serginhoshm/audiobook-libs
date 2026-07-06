#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_DIR="$ROOT_DIR/.run/webapp"
VENV_DIR="${VENV_DIR:-$ROOT_DIR/.venv}"
VENV_PY="$VENV_DIR/bin/python"
MANAGE_PY="$ROOT_DIR/django_app/manage.py"

stop_by_pidfile() {
  local name="$1"
  local pid_file="$2"

  if [ ! -f "$pid_file" ]; then
    echo "[stop_webapp] $name has no pid file"
    return 0
  fi

  local pid
  pid="$(cat "$pid_file")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" || true
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" || true
    fi
    echo "[stop_webapp] $name stopped ($pid)"
  else
    echo "[stop_webapp] $name was not running"
  fi

  rm -f "$pid_file"
}

if [ -x "$VENV_PY" ] && [ -f "$MANAGE_PY" ]; then
  "$VENV_PY" "$MANAGE_PY" stop_active_runs || echo "[stop_webapp] warning: failed to synchronize stop_active_runs"
else
  echo "[stop_webapp] warning: Django environment unavailable for stop_active_runs"
fi

stop_by_pidfile "web" "$RUN_DIR/web.pid"
stop_by_pidfile "worker" "$RUN_DIR/worker.pid"

echo "[stop_webapp] completed"
