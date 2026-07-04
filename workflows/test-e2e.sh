#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG_FILE="${PIPELINE_CONFIG:-$ROOT_DIR/config/pipeline.ini}"

PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
PIPER_BIN="${PIPER_BIN:-$ROOT_DIR/bin/piper}"
MODELS_DIR="$ROOT_DIR/models"
VOICE_MODEL="pt_BR-faber-medium.onnx"
TRANSLATION_BACKEND="${TRANSLATION_BACKEND:-google}"
NLLB_MODEL_DIR="${NLLB_MODEL_DIR:-$ROOT_DIR/models/nllb/facebook-nllb-200-distilled-600M}"

read_ini_value() {
    local file="$1"
    local section="$2"
    local key="$3"
    local default_value="$4"

    if [ ! -f "$file" ]; then
        printf '%s' "$default_value"
        return 0
    fi

    local value
    value="$(awk -F '=' -v section="$section" -v key="$key" '
        BEGIN { in_section=0 }
        /^[[:space:]]*\[/ {
            in_section = ($0 ~ "^[[:space:]]*\\[" section "\\][[:space:]]*$")
            next
        }
        in_section == 1 {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line ~ /^[#;]/ || line == "") next
            split(line, a, "=")
            k=a[1]
            sub(/^[[:space:]]+/, "", k)
            sub(/[[:space:]]+$/, "", k)
            if (k == key) {
                v=substr(line, index(line, "=")+1)
                sub(/^[[:space:]]+/, "", v)
                sub(/[[:space:]]+$/, "", v)
                print v
                exit
            }
        }
    ' "$file")"

    if [ -z "$value" ]; then
        printf '%s' "$default_value"
    else
        printf '%s' "$value"
    fi
}

configure_data_scope() {
    local configured_path

    configured_path="$(read_ini_value "$CONFIG_FILE" "paths" "data_root_relative" "data")"

    if [ -z "$configured_path" ]; then
        echo "Config invalida: data_root_relative vazio" >&2
        return 1
    fi

    if [[ "$configured_path" = /* ]]; then
        DATA_ROOT_ABS="$(realpath -m "$configured_path")"
    else
        DATA_ROOT_ABS="$(realpath -m "$ROOT_DIR/$configured_path")"
    fi

    if [ ! -d "$DATA_ROOT_ABS" ]; then
        echo "Diretorio de escopo nao encontrado: $DATA_ROOT_ABS" >&2
        return 1
    fi

    if [ ! -r "$DATA_ROOT_ABS" ] || [ ! -w "$DATA_ROOT_ABS" ]; then
        echo "Sem permissao de leitura/escrita no escopo: $DATA_ROOT_ABS" >&2
        return 1
    fi

    return 0
}

if ! configure_data_scope; then
    exit 1
fi

LOG_DIR="$DATA_ROOT_ABS/logs"
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

    E2E_DIR="$ROOT_DIR/e2e"
    mkdir -p "$E2E_DIR"

    run_language_e2e() {
        local language_label="$1"
        local input_audio="$2"
        local output_prefix="$3"

        local transcript_srt="$E2E_DIR/${output_prefix}_${language_label}.srt"
        local translated_srt="$E2E_DIR/${output_prefix}_${language_label}.srtpt"
        local output_wav="$E2E_DIR/${output_prefix}_${language_label}.wav"

        if [ ! -f "$input_audio" ]; then
            log_error "Arquivo de teste não encontrado: $input_audio"
            log_summary "FALHA" "Test audio missing"
            exit 1
        fi

        rm -f \
            "$E2E_DIR/${output_prefix}_${language_label}.srt" \
            "$E2E_DIR/${output_prefix}_${language_label}.srtpt" \
            "$E2E_DIR/${output_prefix}_${language_label}.wav"

        whisper_lang="auto"
        source_lang="auto"
        if [ "$language_label" = "spanish" ]; then
            whisper_lang="es"
            source_lang="es"
        elif [ "$language_label" = "chinese" ]; then
            whisper_lang="zh"
            source_lang="zh-CN"
        fi

        log_section "E2E ${language_label^^}: Transcrição"
        "$PYTHON_BIN" -u scripts/transcrever.py \
            "$input_audio" \
            "$E2E_DIR" \
            "$whisper_lang" \
            "medium" \
            "${output_prefix}_${language_label}"

        if [ ! -f "$transcript_srt" ]; then
            log_error "SRT de transcrição não encontrado: $transcript_srt"
            log_summary "FALHA" "SRT ausente"
            exit 1
        fi

        log_section "E2E ${language_label^^}: Tradução"
        "$PYTHON_BIN" scripts/traduzir.py \
            "$transcript_srt" \
            "$translated_srt" \
            "$source_lang" \
            --backend "$TRANSLATION_BACKEND" \
            --nllb-model-dir "$NLLB_MODEL_DIR"

        if [ ! -f "$translated_srt" ]; then
            log_error "SRT traduzido não encontrado: $translated_srt"
            log_summary "FALHA" "SRT traduzido ausente"
            exit 1
        fi

        log_section "E2E ${language_label^^}: Geração de Áudio"
        "$PYTHON_BIN" -u scripts/gerar-sincronizado.py \
            --srt "$translated_srt" \
            --output "$output_wav" \
            --model "$MODELS_DIR/$VOICE_MODEL" \
            --piper "$PIPER_BIN" \
            --source_lang "$source_lang" \
            --pause_duration 0.1

        if [ ! -f "$output_wav" ]; then
            log_error "Saída de áudio E2E não encontrada: $output_wav"
            log_summary "FALHA" "E2E WAV ausente"
            exit 1
        fi

        log_step "E2E ${language_label^^} concluído: $output_wav"
    }

    run_language_e2e "spanish" "$ROOT_DIR/e2e/e2e-test_spanish.wav" "e2e-test-spanish"
    run_language_e2e "chinese" "$ROOT_DIR/e2e/e2e-test_chinese.mp3" "e2e-test-chinese"

    log_summary "SUCCESS" ""
} 2>&1 | tee -a "$LOG_FILE"
