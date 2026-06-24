#!/usr/bin/env bash

set -euo pipefail

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
    log_header
    log_section "Preparação do Ambiente"
    log_step "Executando setup/install_all.sh para garantir artefatos locais"
    bash setup/install_all.sh

    E2E_DIR="$ROOT_DIR/data/e2e"
    mkdir -p "$E2E_DIR"

    run_language_e2e() {
        local language_label="$1"
        local input_audio="$2"
        local output_prefix="$3"

        local transcript_srt="$E2E_DIR/${output_prefix}_${language_label}.srt"
        local translated_srt="$E2E_DIR/${output_prefix}_${language_label}.pt.srt"
        local output_wav="$E2E_DIR/${output_prefix}_${language_label}.wav"

        if [ ! -f "$input_audio" ]; then
            log_error "Arquivo de teste não encontrado: $input_audio"
            log_summary "FALHA" "Test audio missing"
            exit 1
        fi

        rm -f \
            "$E2E_DIR/${output_prefix}_${language_label}.json" \
            "$E2E_DIR/${output_prefix}_${language_label}.srt" \
            "$E2E_DIR/${output_prefix}_${language_label}.tsv" \
            "$E2E_DIR/${output_prefix}_${language_label}.txt" \
            "$E2E_DIR/${output_prefix}_${language_label}.vtt" \
            "$E2E_DIR/${output_prefix}_${language_label}.pt.srt" \
            "$E2E_DIR/${output_prefix}_${language_label}.wav"

        log_section "E2E ${language_label^^}: Transcrição"
        bash workflows/1-transcrever.sh --input-file "$input_audio" "$output_prefix" "auto" "medium" "$E2E_DIR"

        if [ ! -f "$transcript_srt" ]; then
            log_error "SRT de transcrição não encontrado: $transcript_srt"
            log_summary "FALHA" "SRT ausente"
            exit 1
        fi

        log_section "E2E ${language_label^^}: Tradução"
        bash workflows/2-traduzir.sh --input-srt "$transcript_srt" "$translated_srt"

        if [ ! -f "$translated_srt" ]; then
            log_error "SRT traduzido não encontrado: $translated_srt"
            log_summary "FALHA" "SRT traduzido ausente"
            exit 1
        fi

        log_section "E2E ${language_label^^}: Geração de Áudio"
        bash workflows/3-gerar-audiobook.sh --input-srt "$translated_srt" "$output_wav"

        if [ ! -f "$output_wav" ]; then
            log_error "Saída de áudio E2E não encontrada: $output_wav"
            log_summary "FALHA" "E2E WAV ausente"
            exit 1
        fi

        log_step "E2E ${language_label^^} concluído: $output_wav"
    }

    run_language_e2e "spanish" "$ROOT_DIR/data/input/e2e-test_spanish.wav" "e2e-test-spanish"
    run_language_e2e "chinese" "$ROOT_DIR/data/input/e2e-test_chinese.mp3" "e2e-test-chinese"

    log_summary "SUCCESS" ""
} 2>&1 | tee -a "$LOG_FILE"
