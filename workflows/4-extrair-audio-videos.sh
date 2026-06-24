#!/usr/bin/env bash

set -e
set -o pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [ "${WORKFLOW_CLEANUP_DONE:-0}" != "1" ]; then
    export WORKFLOW_CLEANUP_DONE=1
    bash "$ROOT_DIR/workflows/5-limpar-outputs.sh" >/dev/null 2>&1 || true
fi

INPUT_DIR="$ROOT_DIR/data/input"

mkdir -p "$ROOT_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$ROOT_DIR/logs/extrair-audio-videos-${TIMESTAMP}.log"
SCRIPT_NAME="extrair-audio-videos"
SCRIPT_START_TIME=$(date +%s)

source "$ROOT_DIR/scripts/log_helpers.sh"

{
    log_header

    log_section "Verificacao de Pre-requisitos"

    if ! command -v ffmpeg >/dev/null 2>&1; then
        log_error "ffmpeg nao encontrado no PATH. Execute setup/install_all.sh para instalar dependencias."
        log_summary "FALHA" "ffmpeg ausente"
        exit 1
    fi

    mkdir -p "$INPUT_DIR"

    mapfile -t VIDEO_FILES < <(
        find "$INPUT_DIR" -type f \( -iname '*.mkv' -o -iname '*.mp4' \) | sort
    )

    if [ "${#VIDEO_FILES[@]}" -eq 0 ]; then
        log_step "Nenhum arquivo de video .mkv ou .mp4 encontrado em $INPUT_DIR"
        log_summary "SUCCESS" "Sem arquivos para processar"
        exit 0
    fi

    log_section "Arquivos de Video Encontrados"
    for video_file in "${VIDEO_FILES[@]}"; do
        log_step "$video_file"
    done

    log_section "Extracao de Audio"

    processed=0
    failed=0

    for video_file in "${VIDEO_FILES[@]}"; do
        output_wav="${video_file%.*}.wav"

        log_step "Processando: $video_file"
        log_step "Saida: $output_wav"

        if [ -f "$output_wav" ]; then
            rm -f "$output_wav"
            log_step "WAV existente removido: $output_wav"
        fi

        if ffmpeg -hide_banner -loglevel error -i "$video_file" -vn "$output_wav"; then
            if [ -f "$output_wav" ]; then
                processed=$((processed + 1))
                log_step "Extracao concluida"
            else
                failed=$((failed + 1))
                log_error "ffmpeg terminou sem gerar arquivo: $output_wav"
            fi
        else
            failed=$((failed + 1))
            log_error "Falha na extracao do arquivo: $video_file"
        fi
    done

    log_section "Resumo"
    log_step "Videos processados com sucesso: $processed"
    log_step "Videos com falha: $failed"

    if [ "$failed" -gt 0 ]; then
        log_summary "FALHA" "Uma ou mais extracoes falharam"
        exit 1
    fi

    log_summary "SUCCESS" ""
} 2>&1 | tee -a "$LOG_FILE"