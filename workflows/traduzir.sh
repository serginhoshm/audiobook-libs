#!/usr/bin/env bash

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
INPUT_SRT="${1:-$ROOT_DIR/data/outputs/output.srt}"
OUTPUT_SRT="${2:-$ROOT_DIR/data/outputs/audio_entrada.pt.srt}"

if [ ! -f "$INPUT_SRT" ]; then
    if [ -f "$ROOT_DIR/data/outputs/audio_entrada.srt" ]; then
        INPUT_SRT="$ROOT_DIR/data/outputs/audio_entrada.srt"
    elif [ -f "$ROOT_DIR/data/outputs/output.srt" ]; then
        INPUT_SRT="$ROOT_DIR/data/outputs/output.srt"
    fi
fi

mkdir -p "$ROOT_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$ROOT_DIR/logs/traduzir-${TIMESTAMP}.log"
SCRIPT_NAME="traduzir"
SCRIPT_START_TIME=$(date +%s)

source "$ROOT_DIR/scripts/log_helpers.sh"

{
    if [ ! -d ".venv" ]; then
        log_error "Ambiente virtual não encontrado."
        log_summary "FALHA" "Ambiente Python não configurado"
        exit 1
    fi

    log_header
    echo "========================================="
    echo " Tradutor SRT ES -> PT-BR"
    echo "========================================="
    echo
    log_section "Verificação de Pré-requisitos"

    if [ ! -f "$INPUT_SRT" ]; then
        log_error "Nenhum arquivo SRT foi encontrado em $INPUT_SRT."
        log_summary "FALHA" "Arquivo SRT ausente"
        exit 1
    fi

    log_step "Arquivo SRT encontrado: $INPUT_SRT"
    log_section "Execução da Tradução"

    mkdir -p "$(dirname "$OUTPUT_SRT")"
    log_step "Iniciando tradução..."

    "$PYTHON_BIN" scripts/traduzir.py "$INPUT_SRT" "$OUTPUT_SRT"

    log_step "Tradução concluída"
    log_summary "SUCCESS" ""
} 2>&1 | tee -a "$LOG_FILE"
