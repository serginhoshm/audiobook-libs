#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_DIR="$ROOT_DIR/.venv"
VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"
WHISPER_MODELS_DIR="$ROOT_DIR/models/faster-whisper"
WHISPER_MODEL_SIZE="${WHISPER_MODEL_SIZE:-medium}"

# Setup logging
mkdir -p "$ROOT_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$ROOT_DIR/logs/install_all-${TIMESTAMP}.log"
SCRIPT_NAME="install_all"
SCRIPT_START_TIME=$(date +%s)

# Source logging functions
source "$ROOT_DIR/scripts/log_helpers.sh"

{

info() {
  echo
  echo "==> $*"
}

warn() {
  echo
  echo "[WARN] $*"
}

require_root_or_sudo() {
  if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    echo "Erro: este script precisa de sudo ou de execução como root." >&2
    exit 1
  fi
}

ensure_system_deps() {
  info "Verificando dependências do sistema..."

  if command -v dnf >/dev/null 2>&1; then
    info "Detectado Fedora/RHEL com dnf."
    sudo dnf install -y \
      python3 \
      python3-pip \
      python3-virtualenv \
      ffmpeg \
      socat \
      wget \
      tar \
      coreutils \
      gcc-c++
  elif command -v apt-get >/dev/null 2>&1; then
    info "Detectado Debian/Ubuntu com apt-get."
    sudo apt-get update
    sudo apt-get install -y \
      python3 \
      python3-pip \
      python3-venv \
      ffmpeg \
      socat \
      wget \
      tar \
      coreutils \
      build-essential
  else
    echo "Gerenciador de pacotes não suportado neste sistema." >&2
    echo "Instale manualmente ffmpeg, socat, python3, python3-pip, python3-venv, wget, tar e build tools." >&2
    exit 1
  fi
}

ensure_virtualenv() {
  info "Garantindo ambiente virtual em $VENV_DIR"
  if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
  fi

  if [ ! -x "$VENV_PYTHON" ]; then
    echo "Erro: Python do ambiente virtual não encontrado em $VENV_PYTHON" >&2
    exit 1
  fi
}

ensure_python_tooling() {
  info "Atualizando ferramentas Python (pip/setuptools/wheel)"
  "$VENV_PYTHON" -m pip install --no-cache-dir --upgrade "pip<26" "setuptools<82" wheel
}

ensure_python_pkg() {
  local pkg="$1"
  local module="$2"
  local extra_args="${3:-}"

  if "$VENV_PYTHON" -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('$module') else 1)"; then
    info "$pkg já está instalado; pulando."
  else
    info "Instalando $pkg..."
    "$VENV_PYTHON" -m pip install --no-cache-dir $extra_args "$pkg"
  fi
}

ensure_cpu_torch() {
  info "Garantindo PyTorch CPU para evitar instalação CUDA pesada"
  if "$VENV_PYTHON" -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('torch') else 1)"; then
    "$VENV_PYTHON" -c "import torch; print('torch=', torch.__version__, 'cuda=', torch.version.cuda)"
  else
    "$VENV_PYTHON" -m pip install --no-cache-dir \
      --extra-index-url https://download.pytorch.org/whl/cpu \
      "torch<3"
  fi
}

ensure_whisper() {
  info "Verificando instalação do Whisper"
  ensure_cpu_torch
  ensure_python_pkg "openai-whisper" "whisper" ""
  ensure_python_pkg "faster-whisper" "faster_whisper" ""

  "$VENV_PYTHON" - <<'PY'
import importlib.util
for name in ("whisper", "faster_whisper"):
    spec = importlib.util.find_spec(name)
    print(f"{name}: {'ok' if spec else 'missing'}")
PY
}

ensure_whisper_model_cache() {
  info "Preparando modelo Whisper local ($WHISPER_MODEL_SIZE)"
  mkdir -p "$WHISPER_MODELS_DIR"

  if [ -f "$WHISPER_MODELS_DIR/$WHISPER_MODEL_SIZE/model.bin" ]; then
    info "Modelo Whisper local já existe em $WHISPER_MODELS_DIR/$WHISPER_MODEL_SIZE"
    return
  fi

  "$VENV_PYTHON" - "$WHISPER_MODEL_SIZE" "$WHISPER_MODELS_DIR" <<'PY'
import sys
from pathlib import Path

from faster_whisper.utils import download_model

size = sys.argv[1]
root = Path(sys.argv[2])
target = root / size
target.mkdir(parents=True, exist_ok=True)

download_model(size, output_dir=str(target), local_files_only=False)
print(f"Whisper pronto em: {target}")
PY
}

ensure_translation_deps() {
  info "Verificando dependências de tradução"
  ensure_python_pkg "deep-translator" "deep_translator" ""
  ensure_python_pkg "tqdm" "tqdm" ""
}

ensure_sync_deps() {
  info "Verificando dependências para sincronização SRT"
  ensure_python_pkg "pysrt" "pysrt" ""
}

ensure_piper() {
  info "Verificando instalação do Piper TTS"
  ensure_python_pkg "piper-tts" "piper" ""

  if [ ! -x "$ROOT_DIR/bin/piper" ] || [ ! -L "$ROOT_DIR/bin/piper" ]; then
    if [ -x "$VENV_DIR/bin/piper" ]; then
      ln -sf "$VENV_DIR/bin/piper" "$ROOT_DIR/bin/piper"
      info "Atalho para o Piper criado em $ROOT_DIR/bin/piper"
    else
      warn "Executável do Piper ainda não encontrado após instalação; você pode precisar executar novamente este script."
    fi
  else
    info "Atalho para o Piper já existe em $ROOT_DIR/bin/piper"
  fi
}

ensure_model() {
  info "Garantindo modelo de voz do Piper"
  mkdir -p "$ROOT_DIR/models"

  MODEL="pt_BR-faber-medium.onnx"
  MODEL_JSON="${MODEL}.json"
  URL="https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/faber/medium"

  if [ ! -s "$ROOT_DIR/models/$MODEL" ]; then
    [ -f "$ROOT_DIR/models/$MODEL" ] && warn "$MODEL existe mas está vazio/corrompido; baixando novamente"
    info "Baixando $MODEL"
    rm -f "$ROOT_DIR/models/$MODEL"
    wget -c "$URL/$MODEL?download=true" -O "$ROOT_DIR/models/$MODEL"
  else
    info "Modelo de voz válido já existe: $ROOT_DIR/models/$MODEL"
  fi

  if [ ! -s "$ROOT_DIR/models/$MODEL_JSON" ]; then
    [ -f "$ROOT_DIR/models/$MODEL_JSON" ] && warn "$MODEL_JSON existe mas está vazio/corrompido; baixando novamente"
    info "Baixando $MODEL_JSON"
    rm -f "$ROOT_DIR/models/$MODEL_JSON"
    wget -c "$URL/$MODEL_JSON?download=true" -O "$ROOT_DIR/models/$MODEL_JSON"
  else
    info "Config do modelo válida já existe: $ROOT_DIR/models/$MODEL_JSON"
  fi
}

main() {
  log_header
  cd "$ROOT_DIR"
  log_section "Instalação de Dependências"
  require_root_or_sudo
  ensure_system_deps
  ensure_virtualenv
  ensure_python_tooling
  ensure_whisper
  ensure_whisper_model_cache
  ensure_translation_deps
  ensure_sync_deps
  ensure_piper
  ensure_model

  log_step "Instalação concluída com sucesso"
  log_summary "SUCCESS" ""
  echo
  echo "Como usar:"
  echo "  source .venv/bin/activate"
  echo "  ./bin/piper --help"
}

main "$@"
} 2>&1 | tee -a "$LOG_FILE"
