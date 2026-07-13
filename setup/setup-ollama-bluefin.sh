#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER_NAME="${OLLAMA_CONTAINER_NAME:-ollama}"
IMAGE="${OLLAMA_IMAGE:-docker.io/ollama/ollama:latest}"
HOST="${OLLAMA_HOST:-127.0.0.1}"
PORT="${OLLAMA_PORT:-11434}"
MODEL="${OLLAMA_MODEL:-qwen2.5:14b}"
OLLAMA_DATA_DIR="${OLLAMA_DATA_DIR:-$HOME/.local/share/ollama}"

info() {
  echo
  echo "==> $*"
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash setup/setup-ollama-bluefin.sh

Environment variables:
  OLLAMA_CONTAINER_NAME   Nome do container (default: ollama)
  OLLAMA_IMAGE            Imagem do container (default: docker.io/ollama/ollama:latest)
  OLLAMA_HOST             Host bind local (default: 127.0.0.1)
  OLLAMA_PORT             Porta local (default: 11434)
  OLLAMA_MODEL            Modelo para pull inicial (default: qwen2.5:14b)
  OLLAMA_DATA_DIR         Pasta persistente dos modelos (default: ~/.local/share/ollama)

Este script e preparado para Bluefin/Fedora immutable usando Podman rootless.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

command -v podman >/dev/null 2>&1 || fail "podman nao encontrado. Instale no host Bluefin e tente novamente."
command -v curl >/dev/null 2>&1 || fail "curl nao encontrado."

mkdir -p "$OLLAMA_DATA_DIR"

info "Baixando imagem do Ollama ($IMAGE)"
podman pull "$IMAGE"

container_exists() {
  podman container exists "$CONTAINER_NAME"
}

container_running() {
  [[ "$(podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)" == "true" ]]
}

model_present() {
  podman exec "$CONTAINER_NAME" ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fx "$MODEL" >/dev/null 2>&1
}

if container_exists; then
  if container_running; then
    info "Container $CONTAINER_NAME ja esta em execucao"
  else
    info "Iniciando container existente $CONTAINER_NAME"
    podman start "$CONTAINER_NAME" >/dev/null
  fi
else
  info "Criando container $CONTAINER_NAME"
  podman run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "$HOST:$PORT:11434" \
    -v "$OLLAMA_DATA_DIR:/root/.ollama:Z" \
    "$IMAGE" >/dev/null
fi

info "Aguardando API do Ollama responder em http://$HOST:$PORT/api/tags"
ready=0
for _ in $(seq 1 60); do
  if curl -fsS "http://$HOST:$PORT/api/tags" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

[[ "$ready" == "1" ]] || fail "Ollama nao ficou pronto dentro do tempo esperado."

if model_present; then
  info "Modelo ja disponivel localmente: $MODEL"
else
  info "Baixando modelo inicial: $MODEL"
  podman exec "$CONTAINER_NAME" ollama pull "$MODEL"
fi

cat <<EOF

[ok] Ollama pronto para uso.
Container: $CONTAINER_NAME
Endpoint: http://$HOST:$PORT
Modelo: $MODEL

Proximo passo (projeto):
  cp "$ROOT_DIR/config/translation/ollama.env.template" "$ROOT_DIR/config/translation/ollama.env"
  # ajuste OLLAMA_HOST/OLLAMA_MODEL se necessario

Para usar no tradutor:
  export TRANSLATION_BACKEND=ollama

EOF
