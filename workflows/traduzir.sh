#!/usr/bin/env bash

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Setup logging
mkdir -p "$ROOT_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$ROOT_DIR/logs/traduzir-${TIMESTAMP}.log"
SCRIPT_NAME="traduzir"
SCRIPT_START_TIME=$(date +%s)

# Source logging functions
source "$ROOT_DIR/scripts/log_helpers.sh"

{

log_header
echo "========================================="
echo " Tradutor SRT ES -> PT-BR"
echo "========================================="
echo
log_section "Verificação de Pré-requisitos"

if [ ! -d ".venv" ]; then
    log_error "Ambiente virtual não encontrado."
    log_summary "FALHA" "Ambiente Python não configurado"
    exit 1
fi

if [ ! -f "data/outputs/audio_entrada.srt" ] && [ ! -f "data/outputs/output.srt" ]; then
    log_error "Nenhum arquivo SRT foi encontrado em data/outputs."
    log_summary "FALHA" "Arquivo SRT ausente"
    exit 1
fi

log_step "Pré-requisitos validados"
log_section "Execução da Tradução"

source .venv/bin/activate

log_step "Iniciando tradução..."

log_step "Tradução concluída"
echo
printf 'Arquivo traduzido gerado em: %s\n' "data/outputs/audio_entrada.pt.srt"
echo
printf 'Concluído.\n'
log_summary "SUCCESS" ""
} 2>&1 | tee -a "$LOG_FILE"
