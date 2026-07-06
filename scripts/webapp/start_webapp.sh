#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

VENV_DIR="${VENV_DIR:-$ROOT_DIR/.venv}"
VENV_PY="$VENV_DIR/bin/python"
RUN_DIR="$ROOT_DIR/.run/webapp"
LOG_DIR="$ROOT_DIR/logs/webapp"
MANAGE_PY="$ROOT_DIR/django_app/manage.py"
HOST="${WEBAPP_HOST:-127.0.0.1}"
PORT="${WEBAPP_PORT:-8000}"

mkdir -p "$RUN_DIR" "$LOG_DIR"

# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

if [ ! -x "$VENV_PY" ]; then
  echo "[start_webapp] venv Python not found: $VENV_PY"
  echo "[start_webapp] run first: bash scripts/webapp/setup_webapp.sh"
  exit 1
fi

if [ -f "$RUN_DIR/web.pid" ] && kill -0 "$(cat "$RUN_DIR/web.pid")" 2>/dev/null; then
  echo "[start_webapp] web is already running"
else
  nohup "$VENV_PY" "$MANAGE_PY" runserver "$HOST:$PORT" > "$LOG_DIR/web.log" 2>&1 &
  echo $! > "$RUN_DIR/web.pid"
fi

if [ -f "$RUN_DIR/worker.pid" ] && kill -0 "$(cat "$RUN_DIR/worker.pid")" 2>/dev/null; then
  echo "[start_webapp] worker is already running"
else
  nohup "$VENV_PY" "$MANAGE_PY" run_worker > "$LOG_DIR/worker.log" 2>&1 &
  echo $! > "$RUN_DIR/worker.pid"
fi

echo "[start_webapp] URL: http://$HOST:$PORT/"
echo "[start_webapp] web pid: $(cat "$RUN_DIR/web.pid")"
echo "[start_webapp] worker pid: $(cat "$RUN_DIR/worker.pid")"
