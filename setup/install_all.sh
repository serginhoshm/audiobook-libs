#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_DIR="$ROOT_DIR/.venv"
VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

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
      wget \
      tar \
      coreutils \
      build-essential
  else
    echo "Gerenciador de pacotes não suportado neste sistema." >&2
    echo "Instale manualmente ffmpeg, python3, python3-pip, python3-venv, wget, tar e build tools." >&2
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

  if [ ! -x "$ROOT_DIR/piper" ] || [ ! -L "$ROOT_DIR/piper" ]; then
    if [ -x "$VENV_DIR/bin/piper" ]; then
      ln -sf "$VENV_DIR/bin/piper" "$ROOT_DIR/piper"
      info "Atalho para o Piper criado em $ROOT_DIR/piper"
    else
      warn "Executável do Piper ainda não encontrado após instalação; você pode precisar executar novamente este script."
    fi
  else
    info "Atalho para o Piper já existe em $ROOT_DIR/piper"
  fi
}

ensure_model() {
  info "Verificando modelo de voz do Piper"
  mkdir -p "$ROOT_DIR/data/models"

  MODEL="pt_BR-faber-medium.onnx"
  MODEL_JSON="${MODEL}.json"

  if [ ! -f "$ROOT_DIR/data/models/$MODEL" ]; then
    warn "Modelo $MODEL ausente. Será baixado na próxima etapa se a rede estiver disponível."
  fi

  if [ ! -f "$ROOT_DIR/data/models/$MODEL_JSON" ]; then
    warn "Arquivo de configuração $MODEL_JSON ausente. Será baixado na próxima etapa se a rede estiver disponível."
  fi
}

main() {
  cd "$ROOT_DIR"
  require_root_or_sudo
  ensure_system_deps
  ensure_virtualenv
  ensure_python_tooling
  ensure_whisper
  ensure_translation_deps
  ensure_sync_deps
  ensure_piper
  ensure_model

  info "Instalação concluída com sucesso."
  echo
  echo "Como usar:"
  echo "  source .venv/bin/activate"
  echo "  ./piper --help"
}

main "$@"
