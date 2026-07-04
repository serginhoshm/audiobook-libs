#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${VENV_DIR:-$ROOT_DIR/.venv}"
MANAGE_PY="$ROOT_DIR/django_app/manage.py"
VENV_PY="$VENV_DIR/bin/python"

if [ ! -d "$VENV_DIR" ]; then
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

"$VENV_PY" -m pip install --upgrade pip
"$VENV_PY" -m pip install -r "$ROOT_DIR/requirements-webapp.txt"

"$VENV_PY" "$MANAGE_PY" makemigrations pipeline_ui
"$VENV_PY" "$MANAGE_PY" migrate

echo "[setup_webapp] concluido"
