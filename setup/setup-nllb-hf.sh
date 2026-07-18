#!/usr/bin/env bash

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_DIR="$ROOT_DIR/.venv"
VENV_PYTHON="$VENV_DIR/bin/python"

NLLB_HF_MODEL="${NLLB_HF_MODEL:-facebook/nllb-200-distilled-600M}"
NLLB_HF_EXPECTED_BYTES="${NLLB_HF_EXPECTED_BYTES:-2600000000}"
NLLB_HF_SITEPKG_EXPECTED_BYTES="${NLLB_HF_SITEPKG_EXPECTED_BYTES:-1500000000}"
CACHE_ROOT="${HF_HOME:-$HOME/.cache/huggingface}"
CACHE_MODEL_DIR="$CACHE_ROOT/hub/models--facebook--nllb-200-distilled-600M"
DATA_ROOT="$(python3 "$ROOT_DIR/scripts/resolve_data_root.py" data-root)"
LOG_DIR="$DATA_ROOT/logs"

is_immutable_host() {
  [ -f /run/ostree-booted ] || command -v rpm-ostree >/dev/null 2>&1
}

dir_size_bytes() {
  local target="$1"
  if [ ! -d "$target" ]; then
    echo "0"
    return 0
  fi
  du -sb "$target" 2>/dev/null | awk '{print $1}'
}

human_bytes() {
  local bytes="${1:-0}"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$bytes"
  else
    echo "${bytes}B"
  fi
}

monitor_download_progress() {
  local pid="$1"
  local expected="${2:-0}"
  while kill -0 "$pid" 2>/dev/null; do
    local current
    current="$(dir_size_bytes "$CACHE_MODEL_DIR")"
    local percent="0"
    if [ "$expected" -gt 0 ]; then
      percent="$(( current * 100 / expected ))"
      if [ "$percent" -gt 99 ]; then
        percent="99"
      fi
    fi

    echo "[download_progress] model_cache=$(human_bytes "$current") (${percent}% estimado)"
    sleep 5
  done
}

monitor_path_progress() {
  local pid="$1"
  local target_path="$2"
  local label="$3"
  local expected="${4:-0}"
  while kill -0 "$pid" 2>/dev/null; do
    local current
    current="$(dir_size_bytes "$target_path")"
    local percent="0"
    if [ "$expected" -gt 0 ]; then
      percent="$(( current * 100 / expected ))"
      if [ "$percent" -gt 99 ]; then
        percent="99"
      fi
    fi

    echo "[download_progress] $label=$(human_bytes "$current") (${percent}% estimado)"
    sleep 5
  done
}

mkdir -p "$LOG_DIR"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/setup-nllb-hf-${TIMESTAMP}.log"

{
  echo "==> setup-nllb-hf"
  echo "==> root: $ROOT_DIR"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 nao encontrado no host." >&2
    if is_immutable_host; then
      echo >&2
      echo "Host imutavel detectado (OSTree/Bluefin)." >&2
      echo "Instale em uma unica transacao e reinicie:" >&2
      echo "  sudo rpm-ostree install python3 python3-pip" >&2
      echo "  systemctl reboot" >&2
      echo >&2
      echo "Alternativa: execute este projeto dentro de toolbox/distrobox." >&2
    fi
    exit 1
  fi

  if [ ! -d "$VENV_DIR" ]; then
    echo "==> creating venv: $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi

  if [ ! -x "$VENV_PYTHON" ]; then
    echo "ERROR: python not found in venv: $VENV_PYTHON" >&2
    exit 1
  fi

  SITE_PACKAGES_DIR="$($VENV_PYTHON - <<'PY'
import site
paths = site.getsitepackages()
print(paths[0] if paths else "")
PY
)"

  echo "==> upgrading pip tooling"
  "$VENV_PYTHON" -m pip install --no-cache-dir --upgrade "pip<26" "setuptools<82" wheel

  echo "==> installing nllb_hf dependencies"
  echo "==> site-packages dir: $SITE_PACKAGES_DIR"
  echo "==> expected site-packages size after deps: $(human_bytes "$NLLB_HF_SITEPKG_EXPECTED_BYTES")"

  before_sitepkg_bytes="$(dir_size_bytes "$SITE_PACKAGES_DIR")"
  echo "[download_progress] site_packages_before=$(human_bytes "$before_sitepkg_bytes")"

  "$VENV_PYTHON" -m pip install --no-cache-dir \
    --extra-index-url https://download.pytorch.org/whl/cpu \
    "torch<3" \
    "transformers>=4.42" \
    "sentencepiece>=0.2" &
  pip_pid=$!

  monitor_path_progress "$pip_pid" "$SITE_PACKAGES_DIR" "site_packages" "$NLLB_HF_SITEPKG_EXPECTED_BYTES"
  wait "$pip_pid"

  after_sitepkg_bytes="$(dir_size_bytes "$SITE_PACKAGES_DIR")"
  delta_sitepkg_bytes="$(( after_sitepkg_bytes - before_sitepkg_bytes ))"
  if [ "$delta_sitepkg_bytes" -lt 0 ]; then
    delta_sitepkg_bytes=0
  fi
  echo "[download_progress] site_packages_after=$(human_bytes "$after_sitepkg_bytes") installed_this_run=$(human_bytes "$delta_sitepkg_bytes")"

  echo "==> validating and warming model cache: $NLLB_HF_MODEL"
  echo "==> cache dir: $CACHE_MODEL_DIR"
  echo "==> expected model size: $(human_bytes "$NLLB_HF_EXPECTED_BYTES")"

  before_bytes="$(dir_size_bytes "$CACHE_MODEL_DIR")"
  echo "[download_progress] before=$(human_bytes "$before_bytes")"

  "$VENV_PYTHON" - "$NLLB_HF_MODEL" <<'PY' &
import sys
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

model_name = sys.argv[1]
print(f"Loading tokenizer/model: {model_name}")
tok = AutoTokenizer.from_pretrained(model_name, use_fast=False)
model = AutoModelForSeq2SeqLM.from_pretrained(model_name)
print("Tokenizer:", tok.__class__.__name__)
print("Model:", model.__class__.__name__)
PY
  warm_pid=$!

  monitor_download_progress "$warm_pid" "$NLLB_HF_EXPECTED_BYTES"
  wait "$warm_pid"

  after_bytes="$(dir_size_bytes "$CACHE_MODEL_DIR")"
  delta_bytes="$(( after_bytes - before_bytes ))"
  if [ "$delta_bytes" -lt 0 ]; then
    delta_bytes=0
  fi
  echo "[download_progress] after=$(human_bytes "$after_bytes") downloaded_this_run=$(human_bytes "$delta_bytes")"

  echo
  echo "Setup concluido."
  echo "Use no pipeline/webapp:"
  echo "  backend = nllb_hf"
  echo "Opcional:"
  echo "  export NLLB_HF_MODEL=$NLLB_HF_MODEL"
} 2>&1 | tee -a "$LOG_FILE"
