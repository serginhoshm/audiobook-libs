#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DATA_DIR="$ROOT_DIR/data"
ARCHIVE_ROOT="$ROOT_DIR/data/outputs/archive"
PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
PIPER_BIN="${PIPER_BIN:-$ROOT_DIR/bin/piper}"
MODELS_DIR="$ROOT_DIR/data/models"
MODEL_SIZE="${MODEL_SIZE:-medium}"
VOICE_MODEL="pt_BR-faber-medium.onnx"

mkdir -p "$ROOT_DIR/logs"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$ROOT_DIR/logs/exec-${TIMESTAMP}.log"
SCRIPT_NAME="Exec"
SCRIPT_START_TIME="$(date +%s)"

source "$ROOT_DIR/scripts/log_helpers.sh"

list_video_files() {
    find "$DATA_DIR" -type f \( -iname '*.mkv' -o -iname '*.mp4' \) \
        ! -path "$ROOT_DIR/data/e2e/*" \
        ! -path "$ROOT_DIR/data/outputs/*" \
        ! -path "$ROOT_DIR/data/models/*" \
        ! -path "$ROOT_DIR/data/saved/*" | sort
}

infer_whisper_lang() {
    local name_lower
    name_lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$name_lower" in
        *spanish*)
            printf 'es'
            ;;
        *chinese*)
            printf 'zh'
            ;;
        *)
            printf 'auto'
            ;;
    esac
}

infer_translation_lang() {
    case "$1" in
        es)
            printf 'es'
            ;;
        zh)
            printf 'zh-CN'
            ;;
        *)
            printf 'auto'
            ;;
    esac
}

archive_previous_outputs() {
    local source_file="$1"
    local source_dir
    local source_base
    local rel_dir
    local target_dir
    local moved=0
    local artifact

    source_dir="$(dirname "$source_file")"
    source_base="$(basename "${source_file%.*}")"

    rel_dir="${source_dir#$ROOT_DIR/data/}"
    if [ "$rel_dir" = "$source_dir" ]; then
        rel_dir="root"
    fi

    target_dir="$ARCHIVE_ROOT/$rel_dir"
    mkdir -p "$target_dir"

    for artifact in \
        "$source_dir/$source_base.json" \
        "$source_dir/$source_base.srt" \
        "$source_dir/$source_base.tsv" \
        "$source_dir/$source_base.txt" \
        "$source_dir/$source_base.vtt" \
        "$source_dir/$source_base.pt.srt" \
        "$source_dir/$source_base.pt.wav"
    do
        if [ -f "$artifact" ]; then
            mv -f "$artifact" "$target_dir/"
            moved=$((moved + 1))
            log_step "Movido para archive: $(basename "$artifact")"
        fi
    done

    if [ "$moved" -eq 0 ]; then
        log_step "Nenhum artefato antigo para arquivar"
    fi
}

process_video() {
    local video_file="$1"
    local selected_dir
    local base_name
    local audio_wav
    local output_srt
    local output_pt_srt
    local output_pt_wav
    local whisper_lang
    local source_lang

    selected_dir="$(dirname "$video_file")"
    base_name="$(basename "${video_file%.*}")"
    audio_wav="$selected_dir/$base_name.wav"
    output_srt="$selected_dir/$base_name.srt"
    output_pt_srt="$selected_dir/$base_name.pt.srt"
    output_pt_wav="$selected_dir/$base_name.pt.wav"

    whisper_lang="$(infer_whisper_lang "$base_name")"
    source_lang="$(infer_translation_lang "$whisper_lang")"

    log_section "Processando video: ${video_file#$ROOT_DIR/}"
    log_step "Idioma transcricao: $whisper_lang"
    log_step "Idioma traducao: $source_lang"

    log_section "Limpeza por Arquivamento"
    archive_previous_outputs "$video_file"

    log_section "Etapa 0 - Extracao de Audio"
    if [ -f "$audio_wav" ]; then
        rm -f "$audio_wav"
        log_step "WAV anterior removido: ${audio_wav#$ROOT_DIR/}"
    fi

    if ! ffmpeg -hide_banner -loglevel error -i "$video_file" -vn "$audio_wav"; then
        log_error "Falha ao gerar WAV: $audio_wav"
        return 1
    fi
    if [ ! -f "$audio_wav" ]; then
        log_error "Falha ao gerar WAV: $audio_wav"
        return 1
    fi
    log_step "WAV gerado: ${audio_wav#$ROOT_DIR/}"

    log_section "Etapa 1 - Transcricao"
    "$PYTHON_BIN" -u "$ROOT_DIR/scripts/transcrever.py" \
        "$audio_wav" \
        "$selected_dir" \
        "$whisper_lang" \
        "$MODEL_SIZE" \
        "$base_name"

    if [ ! -f "$output_srt" ]; then
        log_error "SRT nao gerado: $output_srt"
        return 1
    fi
    log_step "Transcricao gerada: ${output_srt#$ROOT_DIR/}"

    log_section "Etapa 2 - Traducao"
    "$PYTHON_BIN" "$ROOT_DIR/scripts/traduzir.py" \
        "$output_srt" \
        "$output_pt_srt" \
        "$source_lang"

    if [ ! -f "$output_pt_srt" ]; then
        log_error "SRT traduzido nao gerado: $output_pt_srt"
        return 1
    fi
    log_step "Traducao gerada: ${output_pt_srt#$ROOT_DIR/}"

    log_section "Etapa 3 - Geracao de Audiobook"
    "$PYTHON_BIN" -u "$ROOT_DIR/scripts/gerar-sincronizado.py" \
        --srt "$output_pt_srt" \
        --output "$output_pt_wav" \
        --model "$MODELS_DIR/$VOICE_MODEL" \
        --piper "$PIPER_BIN" \
        --pause_duration 0.1

    if [ ! -f "$output_pt_wav" ]; then
        log_error "Audio final nao gerado: $output_pt_wav"
        return 1
    fi
    log_step "Audiobook gerado: ${output_pt_wav#$ROOT_DIR/}"

    return 0
}

{
    log_header
    log_section "Pre-requisitos"

    if [ ! -x "$PYTHON_BIN" ]; then
        log_error "Python do ambiente virtual nao encontrado: $PYTHON_BIN"
        log_summary "FALHA" "Python indisponivel"
        exit 1
    fi

    if ! command -v ffmpeg >/dev/null 2>&1; then
        log_error "ffmpeg nao encontrado no PATH"
        log_summary "FALHA" "ffmpeg ausente"
        exit 1
    fi

    if [ ! -x "$PIPER_BIN" ]; then
        log_error "Piper nao encontrado ou sem permissao: $PIPER_BIN"
        log_summary "FALHA" "Piper ausente"
        exit 1
    fi

    if [ ! -f "$MODELS_DIR/$VOICE_MODEL" ] || [ ! -f "$MODELS_DIR/$VOICE_MODEL.json" ]; then
        log_error "Modelo de voz Faber ausente em $MODELS_DIR"
        log_summary "FALHA" "Modelo de voz ausente"
        exit 1
    fi

    mkdir -p "$ARCHIVE_ROOT"

    log_section "Selecao de Video"
    mapfile -t VIDEO_FILES < <(list_video_files)

    if [ "${#VIDEO_FILES[@]}" -eq 0 ]; then
        log_error "Nenhum arquivo .mkv/.mp4 encontrado em data/"
        log_summary "FALHA" "Sem videos"
        exit 1
    fi

    echo ""
    echo "Videos disponiveis para processamento:"
    i=1
    for video in "${VIDEO_FILES[@]}"; do
        rel="${video#$ROOT_DIR/}"
        echo "  $i) $rel"
        i=$((i + 1))
    done
    echo ""
    echo "  T) Processar TODOS os videos listados"
    echo ""

    read -r -p "Selecione o numero do video (ou T para TODOS): " choice

    SELECTED_VIDEOS=()
    if [[ "$choice" =~ ^[Tt]$ ]]; then
        SELECTED_VIDEOS=("${VIDEO_FILES[@]}")
        log_step "Modo selecionado: TODOS (${#SELECTED_VIDEOS[@]} videos)"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#VIDEO_FILES[@]}" ]; then
        SELECTED_VIDEOS=("${VIDEO_FILES[$((choice - 1))]}")
        log_step "Modo selecionado: video unico"
    else
        log_error "Selecao invalida: $choice"
        log_summary "FALHA" "Selecao invalida"
        exit 1
    fi

    success_count=0
    fail_count=0
    for selected_video in "${SELECTED_VIDEOS[@]}"; do
        if process_video "$selected_video"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done

    log_section "Resumo Final"
    log_step "Videos com sucesso: $success_count"
    log_step "Videos com falha: $fail_count"

    if [ "$fail_count" -gt 0 ]; then
        log_summary "FALHA" "Uma ou mais execucoes falharam"
        exit 1
    fi

    log_summary "SUCCESS" ""
} 2>&1 | tee -a "$LOG_FILE"
