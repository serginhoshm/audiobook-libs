#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_DIR="$ROOT_DIR/.venv"
VENV_PYTHON="$VENV_DIR/bin/python"

NLLB_MODEL_ID="${NLLB_MODEL_ID:-facebook/nllb-200-distilled-600M}"
NLLB_MODEL_DIR="${NLLB_MODEL_DIR:-$ROOT_DIR/models/nllb/facebook-nllb-200-distilled-600M}"
PIP_INDEX_URLS_DEFAULT="https://pypi.org/simple https://pypi.tuna.tsinghua.edu.cn/simple https://mirrors.aliyun.com/pypi/simple"
PIP_INDEX_URLS="${PIP_INDEX_URLS:-$PIP_INDEX_URLS_DEFAULT}"
HF_ENDPOINTS_DEFAULT="https://huggingface.co https://hf-mirror.com"
HF_ENDPOINTS="${HF_ENDPOINTS:-$HF_ENDPOINTS_DEFAULT}"

mkdir -p "$ROOT_DIR/logs"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$ROOT_DIR/logs/setup-nllb-local-${TIMESTAMP}.log"
SCRIPT_NAME="setup-nllb-local"
SCRIPT_START_TIME="$(date +%s)"

source "$ROOT_DIR/scripts/log_helpers.sh"

{
  install_with_pip_mirrors() {
    local args=("$@")
    local index_url

    for index_url in $PIP_INDEX_URLS; do
      log_step "Tentando instalar com indice pip: $index_url"
      if "$VENV_PYTHON" -m pip install --no-cache-dir --index-url "$index_url" "${args[@]}"; then
        return 0
      fi
      log_step "Indice falhou: $index_url"
    done

    return 1
  }

  download_model_with_hf_endpoints() {
    local endpoint

    for endpoint in $HF_ENDPOINTS; do
      log_step "Tentando baixar modelo via endpoint: $endpoint"
      if HF_ENDPOINT="$endpoint" "$VENV_PYTHON" - "$NLLB_MODEL_ID" "$NLLB_MODEL_DIR" <<'PY'
import sys
from pathlib import Path

from huggingface_hub import snapshot_download

model_id = sys.argv[1]
model_dir = Path(sys.argv[2])
model_dir.mkdir(parents=True, exist_ok=True)

snapshot_download(
    repo_id=model_id,
    local_dir=str(model_dir),
    local_dir_use_symlinks=False,
    resume_download=True,
)

print(f"Modelo pronto em: {model_dir}")
PY
      then
        return 0
      fi
      log_step "Endpoint falhou: $endpoint"
    done

    return 1
  }

  log_header

  log_section "Preparacao"
  if [ ! -d "$VENV_DIR" ]; then
    log_step "Criando ambiente virtual em $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi

  if [ ! -x "$VENV_PYTHON" ]; then
    log_error "Python do ambiente virtual nao encontrado: $VENV_PYTHON"
    log_summary "FALHA" "venv invalido"
    exit 1
  fi

  log_step "Atualizando pip/setuptools/wheel"
  "$VENV_PYTHON" -m pip install --no-cache-dir --upgrade "pip<26" "setuptools<82" wheel

  log_step "Garantindo dependencias Python para NLLB local"
  if ! install_with_pip_mirrors \
    --extra-index-url https://download.pytorch.org/whl/cpu \
    "torch<3" \
    "transformers>=4.42" \
    "sentencepiece>=0.2" \
    "huggingface_hub>=0.24"; then
    log_error "Nao foi possivel instalar dependencias Python em nenhum indice configurado"
    log_summary "FALHA" "Dependencias Python indisponiveis"
    exit 1
  fi

  log_section "Download do Modelo"
  log_step "Modelo: $NLLB_MODEL_ID"
  log_step "Destino local: $NLLB_MODEL_DIR"
  if ! download_model_with_hf_endpoints; then
    log_error "Nao foi possivel baixar modelo em nenhum endpoint configurado"
    log_summary "FALHA" "Download do modelo indisponivel"
    exit 1
  fi

  log_section "Validacao"
  "$VENV_PYTHON" - "$NLLB_MODEL_DIR" <<'PY'
import sys

from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

model_dir = sys.argv[1]
tok = AutoTokenizer.from_pretrained(model_dir, use_fast=False)
model = AutoModelForSeq2SeqLM.from_pretrained(model_dir)
print("Tokenizer:", tok.__class__.__name__)
print("Model:", model.__class__.__name__)
PY

  log_step "Setup NLLB local concluido"
  log_summary "SUCCESS" ""

  echo
  echo "Para usar no pipeline:"
  echo "  export TRANSLATION_BACKEND=nllb_local"
  echo "  export NLLB_MODEL_DIR=$NLLB_MODEL_DIR"
  echo "Opcional (fallback de fontes):"
  echo "  export PIP_INDEX_URLS=\"https://pypi.org/simple https://seu-espelho/simple\""
  echo "  export HF_ENDPOINTS=\"https://huggingface.co https://hf-mirror.com\""
  echo "  bash workflows/exec.sh"
} 2>&1 | tee -a "$LOG_FILE"
