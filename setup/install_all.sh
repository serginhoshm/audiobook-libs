#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_DIR="$ROOT_DIR/.venv"
VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"
WHISPER_MODELS_DIR="$ROOT_DIR/models/faster-whisper"
WHISPER_MODEL_SIZE="${WHISPER_MODEL_SIZE:-medium}"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

# Setup logging
DATA_ROOT="$(python3 "$ROOT_DIR/scripts/resolve_data_root.py" data-root)"
LOG_DIR="$DATA_ROOT/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/install_all-${TIMESTAMP}.log"
SCRIPT_NAME="install_all"
SCRIPT_START_TIME=$(date +%s)

LOG_HELPER="$ROOT_DIR/scripts/pipeline_logging.py"
if [ -x "$VENV_PYTHON" ]; then
  LOG_PYTHON="$VENV_PYTHON"
else
  LOG_PYTHON="$(command -v python3 || true)"
fi

log_header() {
  if [ -n "$LOG_PYTHON" ] && [ -f "$LOG_HELPER" ]; then
    "$LOG_PYTHON" "$LOG_HELPER" header --script-name "$SCRIPT_NAME" --log-file "$LOG_FILE"
  fi
}

log_section() {
  local section="$1"
  if [ -n "$LOG_PYTHON" ] && [ -f "$LOG_HELPER" ]; then
    "$LOG_PYTHON" "$LOG_HELPER" section --title "$section"
  fi
}

log_step() {
  local step="$1"
  if [ -n "$LOG_PYTHON" ] && [ -f "$LOG_HELPER" ]; then
    "$LOG_PYTHON" "$LOG_HELPER" step --message "$step"
  else
    echo "  ✓ $step"
  fi
}

log_error() {
  local error="$1"
  if [ -n "$LOG_PYTHON" ] && [ -f "$LOG_HELPER" ]; then
    "$LOG_PYTHON" "$LOG_HELPER" error --message "$error"
  else
    echo "  ✗ ERROR: $error" >&2
  fi
}

log_summary() {
  local status="$1"
  local error_msg="${2:-}"
  if [ -n "$LOG_PYTHON" ] && [ -f "$LOG_HELPER" ]; then
    "$LOG_PYTHON" "$LOG_HELPER" summary \
      --script-name "$SCRIPT_NAME" \
      --status "$status" \
      --start-time "$SCRIPT_START_TIME" \
      --error-message "$error_msg"
  fi
}

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

is_immutable_host() {
  [ -f /run/ostree-booted ] || command -v rpm-ostree >/dev/null 2>&1
}

missing_cmds() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    printf '%s\n' "${missing[@]}"
  fi

  # Always return success so callers can safely consume output under set -e.
  return 0
}

ensure_system_deps() {
  info "Verificando dependências do sistema..."

  local required_cmds=(python3 pip3 ffmpeg yt-dlp socat wget tar git ip firewall-cmd)
  local build_cmds=(gcc g++)
  local missing_required=()
  local missing_build=()
  local cmd

  while IFS= read -r cmd; do
    [ -n "$cmd" ] && missing_required+=("$cmd")
  done < <(missing_cmds "${required_cmds[@]}")

  while IFS= read -r cmd; do
    [ -n "$cmd" ] && missing_build+=("$cmd")
  done < <(missing_cmds "${build_cmds[@]}")

  if is_immutable_host; then
    info "Detectado sistema imutável (OSTree/Bluefin)."

    if [ "${#missing_required[@]}" -eq 0 ] && [ "${#missing_build[@]}" -eq 0 ]; then
      info "Dependências essenciais já disponíveis no host; pulando instalação de pacotes do sistema."
      return
    fi

    warn "Dependências ausentes no host imutável."
    echo "Faltando (runtime): ${missing_required[*]:-(nenhuma)}"
    echo "Faltando (build): ${missing_build[*]:-(nenhuma)}"

    # Em sistemas OSTree, aplique tudo em uma unica transacao para evitar
    # multiplas reinicializacoes e divergencia entre camadas.
    local rpm_ostree_pkgs=(
      python3
      python3-pip
      ffmpeg
      yt-dlp
      socat
      wget
      tar
      git
      iproute
      firewalld
      gcc
      gcc-c++
    )

    if [ "${#rpm_ostree_pkgs[@]}" -gt 0 ]; then
      echo
      echo "No Bluefin/Fedora imutável, instale todos os pacotes de SO em um unico passo e reinicie:"
      echo "  sudo rpm-ostree install ${rpm_ostree_pkgs[*]}"
      echo "  systemctl reboot"
      echo
      echo "Depois do reboot, execute novamente:"
      echo "  ./setup/install_all.sh"
      echo
      echo "Alternativa: executar este projeto dentro de um toolbox/distrobox com essas dependências."
    fi
    exit 1
  fi

  if command -v dnf >/dev/null 2>&1; then
    info "Detectado Fedora/RHEL com dnf."
    $SUDO dnf install -y --skip-unavailable --skip-broken \
      python3 \
      python3-pip \
      python3-virtualenv \
      yt-dlp \
      socat \
      wget \
      tar \
        git \
        iproute \
        firewalld \
      coreutils \
      gcc-c++

    if command -v ffmpeg >/dev/null 2>&1; then
      info "ffmpeg já está disponível; pulando instalação de pacote ffmpeg."
    else
      warn "ffmpeg não encontrado no PATH; tentando instalar (ffmpeg ou ffmpeg-free)."
      if ! $SUDO dnf install -y --skip-unavailable --skip-broken ffmpeg; then
        warn "Falha ao instalar pacote ffmpeg; tentando ffmpeg-free."
        $SUDO dnf install -y --skip-unavailable --skip-broken ffmpeg-free || \
          warn "Não foi possível instalar ffmpeg/ffmpeg-free automaticamente."
      fi
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    info "Detectado Debian/Ubuntu com apt-get."
    $SUDO apt-get update
    $SUDO apt-get install -y \
      python3 \
      python3-pip \
      python3-venv \
      ffmpeg \
      yt-dlp \
      socat \
      wget \
      tar \
      git \
      iproute2 \
      ufw \
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

  if [ -d "$VENV_DIR" ] && [ ! -x "$VENV_PYTHON" ]; then
    warn "Venv existente, mas Python não está executável (possível symlink quebrado). Recriando venv."
    rm -rf "$VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi

  if [ ! -x "$VENV_PYTHON" ]; then
    echo "Erro: Python do ambiente virtual não encontrado em $VENV_PYTHON" >&2
    exit 1
  fi

  if ! "$VENV_PYTHON" -m pip --version >/dev/null 2>&1; then
    warn "pip ausente no venv; tentando bootstrap com ensurepip"
    if ! "$VENV_PYTHON" -m ensurepip --upgrade >/dev/null 2>&1; then
      warn "Falha no ensurepip; recriando ambiente virtual"
      rm -rf "$VENV_DIR"
      python3 -m venv "$VENV_DIR"
    fi
  fi

  if ! "$VENV_PYTHON" -m pip --version >/dev/null 2>&1; then
    echo "Erro: não foi possível disponibilizar pip em $VENV_DIR." >&2
    echo "Tente remover manualmente $VENV_DIR e executar novamente." >&2
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
  info "Garantindo PyTorch CPU-only"
  if "$VENV_PYTHON" -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('torch') else 1)"; then
    "$VENV_PYTHON" -c "import torch; print('torch=', torch.__version__); print('device=cpu-only')"
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
  ensure_python_pkg "google-generativeai" "google.generativeai" ""
  ensure_python_pkg "ollama" "ollama" ""
  ensure_python_pkg "socksio" "socksio" ""
}

ensure_sync_deps() {
  info "Verificando dependências para sincronização SRT"
  ensure_python_pkg "pysrt" "pysrt" ""
}

ensure_youtube_deps() {
  info "Verificando dependências do workflow YouTube"
  ensure_python_pkg "yt-dlp" "yt_dlp" ""
}

ensure_webapp_python_deps() {
  info "Verificando dependências Python da Webapp (inclui Django)"

  if [ ! -f "$ROOT_DIR/requirements-webapp.txt" ]; then
    warn "Arquivo requirements-webapp.txt não encontrado; pulando setup da webapp"
    return
  fi

  "$VENV_PYTHON" -m pip install --no-cache-dir -r "$ROOT_DIR/requirements-webapp.txt"
}

ensure_piper() {
  info "Verificando instalação do Piper TTS"
  ensure_python_pkg "piper-tts" "piper" ""

  cat > "$ROOT_DIR/bin/piper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  VENV_PYTHON="$ROOT_DIR/.venv/bin/python"

  if [ ! -x "$VENV_PYTHON" ]; then
    echo "ERROR: Python from venv not found at $VENV_PYTHON" >&2
  echo "Run ./setup/install_all.sh to install dependencies." >&2
  exit 1
fi

  # Execute Piper through the venv interpreter to avoid broken shebangs in
  # generated console entrypoints (e.g. after moving/cloning the project).
  exec "$VENV_PYTHON" -m piper "$@"
EOF
  chmod +x "$ROOT_DIR/bin/piper"
  info "Wrapper portável do Piper garantido em $ROOT_DIR/bin/piper"
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
  ensure_youtube_deps
  # Legacy optional setup kept commented for future reactivation.
  # bash "$ROOT_DIR/setup/libretranslate/setup_libretranslate.sh"
  ensure_webapp_python_deps
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
