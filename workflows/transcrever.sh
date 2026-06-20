#!/usr/bin/env bash

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
INPUT_AUDIO="${1:-$ROOT_DIR/data/inputs/audio_entrada.mp3}"
OUTPUT_BASE="${2:-$(basename "${INPUT_AUDIO%.*}")}"
LANGUAGE="${3:-es}"
MODEL_SIZE="${4:-tiny}"

if [ ! -f "$INPUT_AUDIO" ] && [ -f "$ROOT_DIR/data/input/audio-model.mp3" ]; then
    INPUT_AUDIO="$ROOT_DIR/data/input/audio-model.mp3"
    OUTPUT_BASE="audio_model"
fi

mkdir -p "$ROOT_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$ROOT_DIR/logs/transcrever-${TIMESTAMP}.log"
SCRIPT_NAME="transcrever"
SCRIPT_START_TIME=$(date +%s)

source "$ROOT_DIR/scripts/log_helpers.sh"

{
    if [ ! -d ".venv" ]; then
        log_error "Ambiente virtual não encontrado."
        log_summary "FALHA" "Ambiente Python não configurado"
        exit 1
    fi

    log_header
    log_section "Verificação de Pré-requisitos"
    log_step "Validando arquivo de entrada"

    OUTPUT_DIR="$ROOT_DIR/data/outputs"

    if [ ! -f "$INPUT_AUDIO" ]; then
        log_error "Arquivo de áudio não encontrado em $INPUT_AUDIO"
        if [ -f "$ROOT_DIR/data/input/audio-model.mp3" ]; then
            INPUT_AUDIO="$ROOT_DIR/data/input/audio-model.mp3"
            OUTPUT_BASE="audio_model"
            log_step "Usando arquivo de teste: $INPUT_AUDIO"
        else
            log_summary "FALHA" "Arquivo de entrada ausente"
            exit 1
        fi
    fi

    log_step "Arquivo de entrada válido"
    log_section "Transcrição de Áudio"

    mkdir -p "$OUTPUT_DIR"
    log_step "Iniciando transcrição..."

    "$PYTHON_BIN" scripts/transcrever.py \
        "$INPUT_AUDIO" \
        "$OUTPUT_DIR" \
        "$LANGUAGE" \
        "$MODEL_SIZE" \
        "$OUTPUT_BASE"

    log_step "Processamento concluído"
    log_summary "SUCCESS" ""
} 2>&1 | tee -a "$LOG_FILE"
