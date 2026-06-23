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
    E2E_DIR="$ROOT_DIR/data/e2e"
    mkdir -p "$E2E_DIR"
    E2E_AUDIO="$E2E_DIR/mini_test.wav"
    E2E_TRANSCRIPT_SRT="$E2E_DIR/audio_model.srt"
    E2E_TRANSLATED_SRT="$E2E_DIR/audio_model.pt.srt"
    E2E_OUTPUT_WAV="$E2E_DIR/output_$(date +%Y%m%d_%H%M%S).wav"

    if [ ! -f "$E2E_AUDIO" ]; then
        log_error "Arquivo de teste $E2E_AUDIO não encontrado."
        log_summary "FALHA" "Test audio missing"
        exit 1
    fi

    log_header
    log_section "Passo 1: Transcrição"
    bash workflows/1-transcrever.sh --input-file "$E2E_AUDIO" "audio_model" "es" "tiny" "$E2E_DIR"

    log_section "Passo 2: Tradução"
    bash workflows/2-traduzir.sh --input-srt "$E2E_TRANSCRIPT_SRT" "$E2E_TRANSLATED_SRT"

    log_section "Passo 3: Geração de Áudio"
    bash workflows/3-gerar-audiobook.sh --input-srt "$E2E_TRANSLATED_SRT" "$E2E_OUTPUT_WAV"

    if [ ! -f "$E2E_OUTPUT_WAV" ]; then
        log_error "Saida de audio E2E nao encontrada: $E2E_OUTPUT_WAV"
        log_summary "FALHA" "E2E WAV ausente"
        exit 1
    fi

    log_step "Áudio de teste gerado: $E2E_OUTPUT_WAV"

    log_summary "SUCCESS" ""
} 2>&1 | tee -a "$LOG_FILE"
