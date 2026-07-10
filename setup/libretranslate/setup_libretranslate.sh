#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

REPO_URL="${LIBRETRANSLATE_REPO_URL:-https://github.com/LibreTranslate/LibreTranslate.git}"
LIBRETRANSLATE_DIR="${LIBRETRANSLATE_DIR:-$ROOT_DIR/external/LibreTranslate}"
VENV_DIR="${LIBRETRANSLATE_VENV_DIR:-$LIBRETRANSLATE_DIR/.venv}"
LIBRETRANSLATE_LOAD_ONLY_LANG_CODES="${LIBRETRANSLATE_LOAD_ONLY_LANG_CODES:-en,es,zh,pt}"
VENV_PY="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

usage() {
  cat <<'EOF'
Usage: bash setup/libretranslate/setup_libretranslate.sh

Environment variables:
  LIBRETRANSLATE_REPO_URL          Git URL to clone (default: official LibreTranslate repo)
  LIBRETRANSLATE_DIR               Local checkout directory (default: external/LibreTranslate)
  LIBRETRANSLATE_VENV_DIR          Virtualenv directory (default: <repo>/.venv)
  LIBRETRANSLATE_LOAD_ONLY_LANG_CODES  Comma-separated language codes to install/load (default: en,es,zh,pt)
  LIBRETRANSLATE_INSTALL_MODELS    Set to 0 to skip LibreTranslate model installation after setup

This script keeps LibreTranslate separate from the project's main setup.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if ! command -v git >/dev/null 2>&1; then
  echo "[libretranslate-setup] git is required" >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/external"

if [ ! -d "$LIBRETRANSLATE_DIR/.git" ]; then
  if [ -e "$LIBRETRANSLATE_DIR" ] && [ ! -d "$LIBRETRANSLATE_DIR/.git" ]; then
    echo "[libretranslate-setup] destination exists and is not a git checkout: $LIBRETRANSLATE_DIR" >&2
    exit 1
  fi
  git clone "$REPO_URL" "$LIBRETRANSLATE_DIR"
else
  git -C "$LIBRETRANSLATE_DIR" pull --ff-only
fi

if [ ! -x "$VENV_PY" ]; then
  python3 -m venv "$VENV_DIR"
fi

"$VENV_PIP" install --upgrade pip setuptools wheel
"$VENV_PIP" install Babel==2.12.1
(
  cd "$LIBRETRANSLATE_DIR"
  "$VENV_PY" scripts/compile_locales.py
)
"$VENV_PIP" install "numpy<2"
"$VENV_PIP" install "$LIBRETRANSLATE_DIR"

if [ "${LIBRETRANSLATE_INSTALL_MODELS:-1}" != "0" ]; then
  if [ -n "$LIBRETRANSLATE_LOAD_ONLY_LANG_CODES" ]; then
    "$VENV_PY" "$LIBRETRANSLATE_DIR/scripts/install_models.py" --load_only_lang_codes "$LIBRETRANSLATE_LOAD_ONLY_LANG_CODES"
  else
    "$VENV_PY" "$LIBRETRANSLATE_DIR/scripts/install_models.py"
  fi
fi

echo "[libretranslate-setup] installed in: $LIBRETRANSLATE_DIR"
echo "[libretranslate-setup] python venv: $VENV_DIR"
echo "[libretranslate-setup] start server with: $VENV_DIR/bin/libretranslate --host 127.0.0.1 --port 5000"