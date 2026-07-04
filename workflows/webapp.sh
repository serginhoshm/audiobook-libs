#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

HOST="${WEBAPP_HOST:-127.0.0.1}"
PORT="${WEBAPP_PORT:-8000}"
URL="http://$HOST:$PORT/"
VENV_DIR="${VENV_DIR:-$ROOT_DIR/.venv}"
VENV_PY="$VENV_DIR/bin/python"
MANAGE_PY="$ROOT_DIR/django_app/manage.py"

run_django_migrate() {
  if [ ! -x "$VENV_PY" ]; then
    echo "[webapp] venv nao encontrada em $VENV_PY"
    echo "[webapp] execute antes: bash workflows/webapp.sh setup"
    exit 1
  fi

  echo "[webapp] aplicando migracoes do Django..."
  "$VENV_PY" "$MANAGE_PY" migrate
}

usage() {
  cat <<'EOF'
Uso: bash workflows/webapp.sh <comando>

Comandos:
  setup    Instala dependencias e aplica migracoes
  start    Sobe web + worker em background
  stop     Para web + worker
  status   Mostra status dos processos
  restart  Reinicia web + worker
  help     Mostra esta ajuda

Atalho:
  Se nenhum comando for informado, usa "start".
EOF
}

cmd="${1:-start}"

case "$cmd" in
  setup)
    bash scripts/webapp/setup_webapp.sh
    ;;
  start)
    run_django_migrate
    bash scripts/webapp/start_webapp.sh
    echo "[webapp] Abra no navegador: $URL"
    ;;
  stop)
    bash scripts/webapp/stop_webapp.sh
    ;;
  status)
    bash scripts/webapp/status_webapp.sh
    echo "[webapp] URL configurada: $URL"
    ;;
  restart)
    bash scripts/webapp/stop_webapp.sh || true
    run_django_migrate
    bash scripts/webapp/start_webapp.sh
    echo "[webapp] Abra no navegador: $URL"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "[webapp] comando invalido: $cmd"
    usage
    exit 1
    ;;
esac
