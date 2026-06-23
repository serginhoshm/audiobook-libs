#!/usr/bin/env bash
set -e
set -o pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
PIPER_BIN="${PIPER_BIN:-$ROOT_DIR/bin/piper}"
MODELS_DIR="$ROOT_DIR/data/models"
OUTPUT_DIR="$ROOT_DIR/data/outputs"
MODE_ARG="${1:-}"
INPUT_SRT=""
OUTPUT_WAV=""
SOURCE_FILE_NAME=""
JOB_ID=""
JOB_CODE=""
ARTIFACTS_DIR="$ROOT_DIR/data/outputs"

source "$ROOT_DIR/workflows/job_utils.sh"

bash "$ROOT_DIR/workflows/0-indexar-inputs.sh" >/dev/null 2>&1 || true

if [ "$MODE_ARG" = "--input-srt" ]; then
    INPUT_SRT="${2:-}"
    OUTPUT_WAV="${3:-}"
    JOB_ID="e2e"
    JOB_CODE="E2E"
    SOURCE_FILE_NAME="$(basename "$INPUT_SRT")"

    if [ -z "$INPUT_SRT" ]; then
        echo "Uso: $0 --input-srt <arquivo_srt> [arquivo_wav_saida]"
        exit 1
    fi
else
    JOB_ID_INPUT="$MODE_ARG"
    OUTPUT_WAV="${2:-}"
    ARTIFACTS_DIR="${3:-$ROOT_DIR/data/outputs}"

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
    INPUT_SRT="$ARTIFACTS_DIR/${OUTPUT_BASE}.pt.srt"
    SOURCE_FILE_NAME="$JOB_FILE_NAME"
fi

if [ ! -f "$INPUT_SRT" ]; then
    echo "Arquivo SRT não encontrado em $INPUT_SRT"
    exit 1
fi

SOURCE_SLUG="$(job_slug "${SOURCE_FILE_NAME%.*}")"
if [ -z "$SOURCE_SLUG" ]; then
    SOURCE_SLUG="input"
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$ROOT_DIR/logs"
LOG_FILE="$ROOT_DIR/logs/gerar-audiobook-job${JOB_ID}-${SOURCE_SLUG}-${TIMESTAMP}.log"
SCRIPT_NAME="gerar-audiobook [${JOB_CODE}]"
SCRIPT_START_TIME=$(date +%s)

source "$ROOT_DIR/scripts/log_helpers.sh"

{
    if [ ! -d ".venv" ]; then
        job_record_step "$JOB_ID" "$JOB_CODE" "3-gerar-audiobook" "FAILED" "Ambiente Python nao configurado"
        log_error "Ambiente virtual não encontrado."
        log_summary "FALHA" "Ambiente Python não configurado"
        exit 1
    fi

    job_record_step "$JOB_ID" "$JOB_CODE" "3-gerar-audiobook" "STARTED" "$INPUT_SRT"

    log_header
    log_section "Configurações de Geração"
    log_step "Job ID: $JOB_ID"
    log_step "Job Code: $JOB_CODE"
    log_step "SRT de entrada: $INPUT_SRT"
    log_step "Piper bin: $PIPER_BIN"

    if [ ! -x "$PIPER_BIN" ]; then
        job_record_step "$JOB_ID" "$JOB_CODE" "3-gerar-audiobook" "FAILED" "Piper ausente"
        log_error "Executavel do Piper nao encontrado ou sem permissao: $PIPER_BIN"
        log_summary "FALHA" "Piper ausente"
        exit 1
    fi

    MODELO="pt_BR-faber-medium.onnx"
    URL="https://huggingface.co/datasets/piper/resolve/main/pt/pt_BR/faber/medium"
    log_step "Voz selecionada: Faber"

    mkdir -p "$MODELS_DIR" "$OUTPUT_DIR"
    if [ ! -f "$MODELS_DIR/$MODELO" ]; then
        if ! wget -c "$URL/$MODELO" -O "$MODELS_DIR/$MODELO"; then
            job_record_step "$JOB_ID" "$JOB_CODE" "3-gerar-audiobook" "FAILED" "Download do modelo falhou"
            log_error "Falha ao baixar modelo: $MODELO"
            log_summary "FALHA" "Download do modelo falhou"
            exit 1
        fi
    fi

    if [ ! -f "$MODELS_DIR/$MODELO.json" ]; then
        if ! wget -c "$URL/$MODELO.json" -O "$MODELS_DIR/$MODELO.json"; then
            job_record_step "$JOB_ID" "$JOB_CODE" "3-gerar-audiobook" "FAILED" "Download da configuracao falhou"
            log_error "Falha ao baixar configuracao do modelo: $MODELO.json"
            log_summary "FALHA" "Download da configuracao falhou"
            exit 1
        fi
    fi

    if [ -n "$OUTPUT_WAV" ]; then
        SAIDA="$OUTPUT_WAV"
    elif [ "$JOB_ID" = "e2e" ]; then
        SAIDA="$OUTPUT_DIR/output_${TIMESTAMP}.wav"
    else
        SAIDA="$OUTPUT_DIR/job_${JOB_ID}_${SOURCE_SLUG}_${TIMESTAMP}.wav"
    fi
    mkdir -p "$(dirname "$SAIDA")"

    log_section "Geração de Áudio"
    log_step "Gerando áudio sincronizado..."

    "$PYTHON_BIN" -u scripts/gerar-sincronizado.py \
        --srt "$INPUT_SRT" \
        --output "$SAIDA" \
        --model "$MODELS_DIR/$MODELO" \
        --piper "$PIPER_BIN" \
        --pause_duration 0.1

    if [ ! -f "$SAIDA" ]; then
        job_record_step "$JOB_ID" "$JOB_CODE" "3-gerar-audiobook" "FAILED" "WAV ausente"
        log_error "Arquivo de saida nao foi gerado: $SAIDA"
        log_summary "FALHA" "WAV ausente"
        exit 1
    fi

    log_step "Audio gerado: $SAIDA"
    job_record_step "$JOB_ID" "$JOB_CODE" "3-gerar-audiobook" "SUCCESS" "$SAIDA"
    log_summary "SUCCESS" ""
} 2>&1 | tee -a "$LOG_FILE"

