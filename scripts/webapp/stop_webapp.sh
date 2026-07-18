#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_DIR="$ROOT_DIR/.run/webapp"
VENV_DIR="${VENV_DIR:-$ROOT_DIR/.venv}"
VENV_PY="$VENV_DIR/bin/python"
MANAGE_PY="$ROOT_DIR/django_app/manage.py"
TARGET_PORT="${WEBAPP_PORT:-8000}"

pid_is_running() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

collect_process_tree() {
  local root_pid="$1"
  local queue="$root_pid"
  local all="$root_pid"

  while [ -n "$queue" ]; do
    local current="${queue%% *}"
    queue="${queue#* }"
    if [ "$queue" = "$current" ]; then
      queue=""
    fi

    local children
    children="$(ps -o pid= --ppid "$current" 2>/dev/null | tr '\n' ' ' | xargs echo -n 2>/dev/null || true)"
    [ -z "$children" ] && continue

    local child
    for child in $children; do
      case " $all " in
        *" $child "*)
          ;;
        *)
          all="$all $child"
          if [ -z "$queue" ]; then
            queue="$child"
          else
            queue="$queue $child"
          fi
          ;;
      esac
    done
  done

  echo "$all" | xargs echo -n
}

terminate_pid_tree() {
  local root_pid="$1"
  [ -z "$root_pid" ] && return 0
  pid_is_running "$root_pid" || return 0

  local pids
  pids="$(collect_process_tree "$root_pid")"
  [ -z "$pids" ] && return 0

  local pid
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done

  local i
  for i in 1 2 3 4 5; do
    local alive=0
    for pid in $pids; do
      if pid_is_running "$pid"; then
        alive=1
        break
      fi
    done
    [ "$alive" -eq 0 ] && return 0
    sleep 1
  done

  for pid in $pids; do
    kill -9 "$pid" 2>/dev/null || true
  done
}

stop_by_pidfile() {
  local name="$1"
  local pid_file="$2"

  if [ ! -f "$pid_file" ]; then
    echo "[stop_webapp] $name has no pid file"
    return 0
  fi

  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if pid_is_running "$pid"; then
    terminate_pid_tree "$pid"
    echo "[stop_webapp] $name stopped ($pid)"
  else
    echo "[stop_webapp] $name was not running"
  fi

  rm -f "$pid_file"
}

sweep_orphaned_instances() {
  # Fallback: stop stale/untracked web/coordinator/worker instances started from this repo.
  local patterns=(
    "$ROOT_DIR/django_app/manage.py [r]unserver"
    "$ROOT_DIR/django_app/manage.py [r]un_worker_coordinator"
    "$ROOT_DIR/django_app/manage.py [r]un_worker_status_collector"
    "$ROOT_DIR/django_app/manage.py [r]un_worker"
  )
  local pattern
  for pattern in "${patterns[@]}"; do
    local pid
    for pid in $(pgrep -f "$pattern" 2>/dev/null || true); do
      terminate_pid_tree "$pid"
      echo "[stop_webapp] orphan stopped ($pid)"
    done
  done

  if command -v lsof >/dev/null 2>&1; then
    local pid
    for pid in $(lsof -tiTCP:"$TARGET_PORT" -sTCP:LISTEN 2>/dev/null || true); do
      terminate_pid_tree "$pid"
      echo "[stop_webapp] listener stopped on :$TARGET_PORT ($pid)"
    done
  fi
}

if [ -x "$VENV_PY" ] && [ -f "$MANAGE_PY" ]; then
  "$VENV_PY" "$MANAGE_PY" stop_active_runs || echo "[stop_webapp] warning: failed to synchronize stop_active_runs"
else
  echo "[stop_webapp] warning: Django environment unavailable for stop_active_runs"
fi

stop_by_pidfile "web" "$RUN_DIR/web.pid"
stop_by_pidfile "coordinator" "$RUN_DIR/coordinator.pid"
stop_by_pidfile "status-collector" "$RUN_DIR/status-collector.pid"
stop_by_pidfile "worker" "$RUN_DIR/worker.pid"
sweep_orphaned_instances

echo "[stop_webapp] completed"
