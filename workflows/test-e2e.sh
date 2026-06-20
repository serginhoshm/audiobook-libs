#!/usr/bin/env bash

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

LOG_DIR="$ROOT_DIR/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/test-e2e-${TIMESTAMP}.log"
SCRIPT_NAME="test-e2e"
SCRIPT_START_TIME=$(date +%s)

source "$ROOT_DIR/scripts/log_helpers.sh"

{
    if [ ! -f "$ROOT_DIR/data/input/audio-model.mp3" ]; then
        log_error "Arquivo de teste data/input/audio-model.mp3 não encontrado."
        log_summary "FALHA" "Test audio missing"
        exit 1
    fi

    log_header
    log_section "Passo 1: Transcrição"
    bash workflows/transcrever.sh "$ROOT_DIR/data/input/audio-model.mp3" "audio_model" "es" "tiny"

    log_section "Passo 2: Tradução"
    bash workflows/traduzir.sh "$ROOT_DIR/data/outputs/audio_model.srt" "$ROOT_DIR/data/outputs/audio_model.pt.srt"

    log_section "Passo 3: Preparar SRT para geração"
    cp -f "$ROOT_DIR/data/outputs/audio_model.pt.srt" "$ROOT_DIR/data/outputs/output.srt"
    log_step "SRT de geração pronto: data/outputs/output.srt"

    log_section "Passo 4: Geração de Áudio"
    printf 'B\n3\n' | bash workflows/gerar-audiobook.sh

    log_summary "SUCCESS" ""
} 2>&1 | tee -a "$LOG_FILE"
