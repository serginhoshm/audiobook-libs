#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_DIR="$ROOT_DIR/.run/webapp"

stop_by_pidfile() {
  local name="$1"
  local pid_file="$2"

  if [ ! -f "$pid_file" ]; then
    echo "[stop_webapp] $name sem pid file"
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
    echo "[stop_webapp] $name encerrado ($pid)"
  else
    echo "[stop_webapp] $name nao estava ativo"
  fi

  rm -f "$pid_file"
}

stop_by_pidfile "web" "$RUN_DIR/web.pid"
stop_by_pidfile "worker" "$RUN_DIR/worker.pid"

echo "[stop_webapp] concluido"
