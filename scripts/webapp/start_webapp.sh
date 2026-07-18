#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

DATA_ROOT="$(python3 "$ROOT_DIR/scripts/resolve_data_root.py" data-root)"

VENV_DIR="${VENV_DIR:-$ROOT_DIR/.venv}"
VENV_PY="$VENV_DIR/bin/python"
RUN_DIR="$ROOT_DIR/.run/webapp"
LOG_DIR="$DATA_ROOT/logs/webapp"
MANAGE_PY="$ROOT_DIR/django_app/manage.py"
HOST="${WEBAPP_HOST:-127.0.0.1}"
PORT="${WEBAPP_PORT:-8000}"
STARTUP_TIMEOUT_SECONDS="${WEBAPP_STARTUP_TIMEOUT_SECONDS:-12}"

mkdir -p "$RUN_DIR" "$LOG_DIR"

# Prevent concurrent start attempts from racing and amplifying SQLite locks.
LOCK_FILE="$RUN_DIR/start.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[start_webapp] another start is already in progress"
  exit 0
fi

pid_is_running() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

cleanup_stale_pidfile() {
  local name="$1"
  local pid_file="$2"

  if [ ! -f "$pid_file" ]; then
    return 0
  fi

  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if pid_is_running "$pid"; then
    return 0
  fi

  rm -f "$pid_file"
  echo "[start_webapp] removed stale $name pid file"
}

wait_for_process_boot() {
  local name="$1"
  local pid_file="$2"
  local log_file="$3"
  local waited=0

  while [ "$waited" -lt "$STARTUP_TIMEOUT_SECONDS" ]; do
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if pid_is_running "$pid"; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  echo "[start_webapp] $name failed to stay running"
  if [ -f "$log_file" ]; then
    echo "[start_webapp] last log lines from $log_file:"
    tail -n 40 "$log_file" || true
  fi
  return 1
}

if [ ! -x "$VENV_PY" ]; then
  echo "[start_webapp] venv Python not found: $VENV_PY"
  echo "[start_webapp] run first: bash scripts/webapp/setup_webapp.sh"
  exit 1
fi

# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

cleanup_stale_pidfile "web" "$RUN_DIR/web.pid"
cleanup_stale_pidfile "worker" "$RUN_DIR/worker.pid"
cleanup_stale_pidfile "coordinator" "$RUN_DIR/coordinator.pid"

# Safer defaults for SQLite contention and disabled LibreTranslate auto-management.
export SQLITE_TIMEOUT_SECONDS="${SQLITE_TIMEOUT_SECONDS:-90}"
export WEBAPP_SQLITE_LOCK_RETRY_ATTEMPTS="${WEBAPP_SQLITE_LOCK_RETRY_ATTEMPTS:-12}"
export WEBAPP_SQLITE_LOCK_RETRY_WAIT_SECONDS="${WEBAPP_SQLITE_LOCK_RETRY_WAIT_SECONDS:-0.5}"
export WEBAPP_WORKER_MANAGE_LIBRETRANSLATE="${WEBAPP_WORKER_MANAGE_LIBRETRANSLATE:-0}"

# To re-enable LibreTranslate worker management in the future:
# export WEBAPP_WORKER_MANAGE_LIBRETRANSLATE=1

if [ -f "$RUN_DIR/web.pid" ] && kill -0 "$(cat "$RUN_DIR/web.pid")" 2>/dev/null; then
  echo "[start_webapp] web is already running"
else
  nohup "$VENV_PY" "$MANAGE_PY" runserver "$HOST:$PORT" --noreload > "$LOG_DIR/web.log" 2>&1 &
  echo $! > "$RUN_DIR/web.pid"
  wait_for_process_boot "web" "$RUN_DIR/web.pid" "$LOG_DIR/web.log"
fi

if [ -f "$RUN_DIR/coordinator.pid" ] && kill -0 "$(cat "$RUN_DIR/coordinator.pid")" 2>/dev/null; then
  echo "[start_webapp] coordinator is already running"
else
  nohup "$VENV_PY" "$MANAGE_PY" run_worker_coordinator > "$LOG_DIR/coordinator.log" 2>&1 &
  echo $! > "$RUN_DIR/coordinator.pid"
  wait_for_process_boot "coordinator" "$RUN_DIR/coordinator.pid" "$LOG_DIR/coordinator.log"
fi

echo "[start_webapp] URL: http://$HOST:$PORT/"
echo "[start_webapp] web pid: $(cat "$RUN_DIR/web.pid")"
echo "[start_webapp] coordinator pid: $(cat "$RUN_DIR/coordinator.pid")"
