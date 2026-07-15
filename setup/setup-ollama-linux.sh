#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OLLAMA_HOST:-127.0.0.1}"
PORT="${OLLAMA_PORT:-11434}"
MODEL="${OLLAMA_MODEL:-qwen2.5:14b}"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

info() {
  echo
  echo "==> $*"
}

warn() {
  echo
  echo "[WARN] $*"
}

fail() {
  echo
  echo "[ERROR] $*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

need_sudo_if_needed() {
  if [ "$(id -u)" -ne 0 ] && ! have_cmd sudo; then
    fail "sudo nao encontrado. Execute como root ou instale sudo."
  fi
}

ensure_system_prereqs() {
  if have_cmd apt-get; then
    info "Garantindo pre-requisitos do sistema (curl, ca-certificates)"
    $SUDO apt-get update
    $SUDO apt-get install -y curl ca-certificates
    return 0
  fi

  warn "apt-get nao encontrado; pulando instalacao automatica de pre-requisitos"
}

install_ollama_if_missing() {
  if have_cmd ollama; then
    info "Ollama ja esta instalado"
    return 0
  fi

  need_sudo_if_needed
  ensure_system_prereqs

  info "Instalando Ollama via instalador oficial"
  curl -fsSL https://ollama.com/install.sh | $SUDO sh

  have_cmd ollama || fail "Ollama nao ficou disponivel no PATH apos a instalacao."
}

ensure_ollama_service() {
  if have_cmd systemctl; then
    info "Habilitando servico Ollama"
    $SUDO systemctl enable --now ollama || true
  else
    warn "systemctl nao encontrado; inicie manualmente com: ollama serve"
  fi
}

wait_for_ollama_api() {
  local endpoint="http://${HOST}:${PORT}/api/tags"
  info "Aguardando API do Ollama em ${endpoint}"

  local attempts=0
  local max_attempts=30
  while [ "$attempts" -lt "$max_attempts" ]; do
    if curl -fsS "$endpoint" >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 1
  done

  fail "Ollama nao respondeu em ${endpoint}. Verifique o servico com: systemctl status ollama --no-pager"
}

pull_model() {
  info "Garantindo modelo local: $MODEL"
  ollama pull "$MODEL"
}

print_next_steps() {
  cat <<EOF

[ok] Ollama pronto para uso.
Endpoint: http://${HOST}:${PORT}
Modelo: ${MODEL}

Proximo passo (projeto):
  cp "$ROOT_DIR/config/translation/ollama.env.template" "$ROOT_DIR/config/translation/ollama.env"
  # ajuste OLLAMA_HOST/OLLAMA_MODEL se necessario

Para usar no tradutor/webapp:
  export TRANSLATION_BACKEND=ollama

EOF
}

main() {
  install_ollama_if_missing
  ensure_ollama_service
  wait_for_ollama_api
  pull_model
  print_next_steps
}

main "$@"