#!/usr/bin/env bash

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
MODE_ARG="${1:-}"
INPUT_SRT=""
OUTPUT_SRT=""
SOURCE_FILE_NAME=""
JOB_ID=""
JOB_CODE=""
ARTIFACTS_DIR="$ROOT_DIR/data/outputs"
SOURCE_LANG=""
LANG_SUFFIX=""

job_detect_language_suffix() {
    local name_lower
    name_lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

    case "$name_lower" in
        *_spanish.srt|*spanish*.srt)
            printf 'spanish|es'
            ;;
        *_chinese.srt|*chinese*.srt)
            printf 'chinese|zh-CN'
            ;;
        *)
            return 1
            ;;
    esac
}

source "$ROOT_DIR/workflows/job_utils.sh"

bash "$ROOT_DIR/workflows/0-indexar-inputs.sh" >/dev/null 2>&1 || true

if [ "$MODE_ARG" = "--input-srt" ]; then
    INPUT_SRT="${2:-}"
    OUTPUT_SRT="${3:-}"
    JOB_ID="e2e"
    JOB_CODE="E2E"
    SOURCE_FILE_NAME="$(basename "$INPUT_SRT")"

    if [ -z "$INPUT_SRT" ]; then
        echo "Uso: $0 --input-srt <arquivo_srt> [arquivo_srt_saida]"
        exit 1
    fi

    if [ -z "$OUTPUT_SRT" ]; then
        OUTPUT_SRT="$(dirname "$INPUT_SRT")/$(basename "${INPUT_SRT%.*}").pt.srt"
    fi

    if ! LANGUAGE_PAIR="$(job_detect_language_suffix "$SOURCE_FILE_NAME")"; then
        echo "Erro: o nome do arquivo SRT deve conter 'spanish' ou 'chinese'."
        exit 1
    fi

    LANG_SUFFIX="${LANGUAGE_PAIR%%|*}"
    SOURCE_LANG="${LANGUAGE_PAIR##*|}"
else
    JOB_ID_INPUT="$MODE_ARG"
    ARTIFACTS_DIR="${2:-$ROOT_DIR/data/outputs}"

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

    OUTPUT_BASE="$(job_output_base "$JOB_ID" "$JOB_FILE_NAME")"

    INPUT_SRT_SPANISH="$ARTIFACTS_DIR/${OUTPUT_BASE}_spanish.srt"
    INPUT_SRT_CHINESE="$ARTIFACTS_DIR/${OUTPUT_BASE}_chinese.srt"

    if [ -f "$INPUT_SRT_SPANISH" ] && [ -f "$INPUT_SRT_CHINESE" ]; then
        echo "Ambiguidade: encontrados arquivos espanhol e chinês para o mesmo job."
        echo "Use modo manual: $0 --input-srt <arquivo_srt>"
        exit 1
    elif [ -f "$INPUT_SRT_SPANISH" ]; then
        INPUT_SRT="$INPUT_SRT_SPANISH"
    elif [ -f "$INPUT_SRT_CHINESE" ]; then
        INPUT_SRT="$INPUT_SRT_CHINESE"
    else
        echo "Erro: não foi encontrado SRT com sufixo _spanish ou _chinese para o job $JOB_ID."
        exit 1
    fi

    if ! LANGUAGE_PAIR="$(job_detect_language_suffix "$(basename "$INPUT_SRT")")"; then
        echo "Erro: o nome do arquivo SRT deve conter 'spanish' ou 'chinese'."
        exit 1
    fi

    LANG_SUFFIX="${LANGUAGE_PAIR%%|*}"
    SOURCE_LANG="${LANGUAGE_PAIR##*|}"

    OUTPUT_SRT="$ARTIFACTS_DIR/${OUTPUT_BASE}_${LANG_SUFFIX}.pt.srt"
    SOURCE_FILE_NAME="$JOB_FILE_NAME"
fi

SOURCE_SLUG="$(job_slug "${SOURCE_FILE_NAME%.*}")"
if [ -z "$SOURCE_SLUG" ]; then
    SOURCE_SLUG="input"
fi

mkdir -p "$ROOT_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$ROOT_DIR/logs/traduzir-job${JOB_ID}-${SOURCE_SLUG}-${TIMESTAMP}.log"
SCRIPT_NAME="traduzir [${JOB_CODE}]"
SCRIPT_START_TIME=$(date +%s)

source "$ROOT_DIR/scripts/log_helpers.sh"

{
    if [ ! -d ".venv" ]; then
        job_record_step "$JOB_ID" "$JOB_CODE" "2-traduzir" "FAILED" "Ambiente Python nao configurado"
        log_error "Ambiente virtual não encontrado."
        log_summary "FALHA" "Ambiente Python não configurado"
        exit 1
    fi

    job_record_step "$JOB_ID" "$JOB_CODE" "2-traduzir" "STARTED" "$INPUT_SRT"

    log_header
    echo "========================================="
    echo " Tradutor SRT (AUTO) -> PT-BR"
    echo "========================================="
    echo
    log_section "Verificação de Pré-requisitos"

    if [ ! -f "$INPUT_SRT" ]; then
        job_record_step "$JOB_ID" "$JOB_CODE" "2-traduzir" "FAILED" "Arquivo SRT ausente"
        log_error "Nenhum arquivo SRT foi encontrado em $INPUT_SRT."
        log_summary "FALHA" "Arquivo SRT ausente"
        exit 1
    fi

    log_step "Arquivo SRT encontrado: $INPUT_SRT"
    log_step "Job ID: $JOB_ID"
    log_step "Job Code: $JOB_CODE"
    log_step "Idioma de origem inferido pelo nome do arquivo: $SOURCE_LANG"
    log_section "Execução da Tradução"

    mkdir -p "$(dirname "$OUTPUT_SRT")"
    log_step "Iniciando tradução..."

    "$PYTHON_BIN" scripts/traduzir.py "$INPUT_SRT" "$OUTPUT_SRT" "$SOURCE_LANG"

    log_step "Tradução concluída"
    job_record_step "$JOB_ID" "$JOB_CODE" "2-traduzir" "SUCCESS" "$OUTPUT_SRT"
    log_summary "SUCCESS" ""
} 2>&1 | tee -a "$LOG_FILE"
