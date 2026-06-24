#!/usr/bin/env bash

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [ "${WORKFLOW_CLEANUP_DONE:-0}" != "1" ]; then
    export WORKFLOW_CLEANUP_DONE=1
    bash "$ROOT_DIR/workflows/5-limpar-outputs.sh" >/dev/null 2>&1 || true
fi

PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
MODE_ARG="${1:-}"
INPUT_AUDIO=""
OUTPUT_BASE=""
LANGUAGE="auto"
# Opções de MODEL_SIZE (da menor para a maior precisão):
# tiny, base, small, medium, large
MODEL_SIZE="medium"
OUTPUT_DIR="$ROOT_DIR/data/outputs"
SOURCE_FILE_NAME=""
JOB_ID=""
JOB_CODE=""
FINAL_OUTPUT_BASE=""
OUTPUT_BASE_NAME=""
LANGUAGE_LABEL=""
WHISPER_LANGUAGE=""

job_detect_language_from_name() {
    local name_lower
    name_lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

    case "$name_lower" in
        *spanish*)
            printf 'spanish|es'
            ;;
        *chinese*)
            printf 'chinese|zh'
            ;;
        *)
            return 1
            ;;
    esac
}

source "$ROOT_DIR/workflows/job_utils.sh"

bash "$ROOT_DIR/workflows/0-indexar-inputs.sh" >/dev/null 2>&1 || true

if [ "$MODE_ARG" = "--input-file" ]; then
    INPUT_AUDIO="${2:-}"
    OUTPUT_BASE="${3:-}"
    LANGUAGE="${4:-auto}"
    MODEL_SIZE="${5:-medium}"
    OUTPUT_DIR="${6:-$ROOT_DIR/data/outputs}"
    SOURCE_FILE_NAME="$(basename "$INPUT_AUDIO")"
    JOB_ID="e2e"
    JOB_CODE="E2E"

    if [ -z "$INPUT_AUDIO" ]; then
        echo "Uso: $0 --input-file <arquivo_de_audio> [output_base] [lingua] [model_size] [output_dir]"
        exit 1
    fi

    if [ -z "$OUTPUT_BASE" ]; then
        OUTPUT_BASE="$(basename "${INPUT_AUDIO%.*}")"
    fi
else
    JOB_ID_INPUT="$MODE_ARG"
    LANGUAGE="${2:-auto}"
    MODEL_SIZE="${3:-medium}"
    OUTPUT_DIR="${4:-$ROOT_DIR/data/outputs}"

    if [ -z "$JOB_ID_INPUT" ]; then
        if ! JOB_ID_INPUT="$(job_prompt_select_id)"; then
            exit 1
        fi
    fi

    if ! job_get_record_by_id "$JOB_ID_INPUT"; then
        echo "Job ID invalido ou inexistente: $JOB_ID_INPUT"
        echo "Execute workflows/0-indexar-inputs.sh para indexar arquivos de data/input/."
        exit 1
    fi

    INPUT_AUDIO="$ROOT_DIR/$JOB_RELATIVE_PATH"
    SOURCE_FILE_NAME="$JOB_FILE_NAME"
    OUTPUT_BASE="$(job_output_base "$JOB_ID" "$SOURCE_FILE_NAME")"
fi

OUTPUT_BASE_NAME="$(basename "$OUTPUT_BASE")"

if ! LANGUAGE_PAIR="$(job_detect_language_from_name "$SOURCE_FILE_NAME")"; then
    echo "Erro: o nome do arquivo deve conter 'spanish' ou 'chinese'."
    exit 1
fi

LANGUAGE_LABEL="${LANGUAGE_PAIR%%|*}"
WHISPER_LANGUAGE="${LANGUAGE_PAIR##*|}"

FINAL_OUTPUT_BASE="${OUTPUT_BASE_NAME}_${LANGUAGE_LABEL}"

SOURCE_SLUG="$(job_slug "${SOURCE_FILE_NAME%.*}")"
if [ -z "$SOURCE_SLUG" ]; then
    SOURCE_SLUG="input"
fi

mkdir -p "$ROOT_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$ROOT_DIR/logs/transcrever-job${JOB_ID}-${SOURCE_SLUG}-${TIMESTAMP}.log"
SCRIPT_NAME="transcrever [${JOB_CODE}]"
SCRIPT_START_TIME=$(date +%s)

source "$ROOT_DIR/scripts/log_helpers.sh"

{
    if [ ! -d ".venv" ]; then
        job_record_step "$JOB_ID" "$JOB_CODE" "1-transcrever" "FAILED" "Ambiente Python nao configurado"
        log_error "Ambiente virtual não encontrado."
        log_summary "FALHA" "Ambiente Python não configurado"
        exit 1
    fi

    job_record_step "$JOB_ID" "$JOB_CODE" "1-transcrever" "STARTED" "$SOURCE_FILE_NAME"

    log_header
    log_section "Verificação de Pré-requisitos"
    log_step "Validando arquivo de entrada"

    if [ ! -f "$INPUT_AUDIO" ]; then
        job_record_step "$JOB_ID" "$JOB_CODE" "1-transcrever" "FAILED" "Arquivo de entrada ausente"
        log_error "Arquivo de áudio não encontrado em $INPUT_AUDIO"
        log_summary "FALHA" "Arquivo de entrada ausente"
        exit 1
    fi

    log_step "Arquivo de entrada válido: $INPUT_AUDIO"
    log_step "Job ID: $JOB_ID"
    log_step "Job Code: $JOB_CODE"
    log_section "Configurações de Transcrição"
    log_step "Idioma inferido pelo nome do arquivo: $LANGUAGE_LABEL"
    log_step "Modelo: $MODEL_SIZE (precisão: menor→tiny, base, small, medium, large←maior)"
    log_step "Diretório de saída: $OUTPUT_DIR"
    
    log_section "Transcrição de Áudio"

    mkdir -p "$OUTPUT_DIR"
    log_step "Iniciando transcrição com modelo $MODEL_SIZE..."

    log_step "[1/3] Carregando modelo $MODEL_SIZE..."
    log_step "[2/3] Processando áudio..."
    
    "$PYTHON_BIN" -u scripts/transcrever.py \
        "$INPUT_AUDIO" \
        "$OUTPUT_DIR" \
        "$WHISPER_LANGUAGE" \
        "$MODEL_SIZE" \
        "$FINAL_OUTPUT_BASE"

    log_step "[3/3] Salvando arquivos de saída..."
    log_step "Processamento concluído com sucesso"
    job_record_step "$JOB_ID" "$JOB_CODE" "1-transcrever" "SUCCESS" "$OUTPUT_DIR/$FINAL_OUTPUT_BASE.srt"
    log_summary "SUCCESS" ""
} 2>&1 | tee -a "$LOG_FILE"
