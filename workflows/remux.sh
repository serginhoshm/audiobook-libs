#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG_FILE="${PIPELINE_CONFIG:-$ROOT_DIR/config/pipeline.ini}"
PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
source "$ROOT_DIR/scripts/log_helpers.sh"

DATA_DIR="$ROOT_DIR/data"
DATA_SCOPE_REL="data"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/remux-${TIMESTAMP}.log"
SCRIPT_NAME="Remux"
SCRIPT_START_TIME="$(date +%s)"

MAX_STEM_LENGTH=120
REMUX_SUFFIX=" (remux)"
REMUX_TOLERANCE="${REMUX_TOLERANCE:-0.5}"

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
    local scope_abs

    configured_path="$(read_ini_value "$CONFIG_FILE" "paths" "data_root_relative" "data")"

    if [ -z "$configured_path" ]; then
        log_error "Config invalida: data_root_relative vazio"
        return 1
    fi

    if [[ "$configured_path" = /* ]]; then
        scope_abs="$(realpath -m "$configured_path")"
    else
        scope_abs="$(realpath -m "$ROOT_DIR/$configured_path")"
    fi

    if [ ! -d "$scope_abs" ]; then
        log_error "Diretorio de escopo nao encontrado: $scope_abs"
        return 1
    fi

    if [ ! -r "$scope_abs" ] || [ ! -w "$scope_abs" ]; then
        log_error "Sem permissao de leitura/escrita no escopo: $scope_abs"
        return 1
    fi

    DATA_SCOPE_REL="$configured_path"
    DATA_DIR="$scope_abs"
    return 0
}

prepare_runtime_paths() {
    LOG_DIR="$DATA_DIR/logs"
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/remux-${TIMESTAMP}.log"
}

bootstrap_runtime() {
    if [ ! -x "$PYTHON_BIN" ]; then
        echo "ERRO: Python do ambiente virtual nao encontrado: $PYTHON_BIN" >&2
        exit 1
    fi

    if ! configure_data_scope; then
        echo "ERRO: Escopo de dados invalido" >&2
        exit 1
    fi

    prepare_runtime_paths
}

read_video_duration() {
    local media_file="$1"
    "$PYTHON_BIN" "$ROOT_DIR/scripts/pipeline_validators.py" media-duration --input "$media_file" | tail -n 1
}

duration_matches() {
    local first="$1"
    local second="$2"
    awk -v a="$first" -v b="$second" -v tol="$REMUX_TOLERANCE" 'BEGIN { diff = a - b; if (diff < 0) diff = -diff; exit(diff <= tol ? 0 : 1) }'
}

normalize_for_system() {
    local stem="$1"
    local source_id="$2"
    local sanitized
    local digest
    local max_head_length

    sanitized="$($PYTHON_BIN - "$stem" <<'PY'
import re
import sys
import unicodedata

text = sys.argv[1]
text = unicodedata.normalize("NFKC", text)
text = text.replace("_", " ").replace("-", " ")
text = re.sub(r"[^0-9A-Za-zÀ-ÖØ-öø-ÿ() ]+", " ", text)
text = re.sub(r"\s+", " ", text).strip()
print(text)
PY
)"
    if [ -z "$sanitized" ]; then
        sanitized="video"
    fi

    if [ ${#sanitized} -le $((MAX_STEM_LENGTH - ${#REMUX_SUFFIX})) ]; then
        printf '%s%s' "$sanitized" "$REMUX_SUFFIX"
        return 0
    fi

    digest="$(printf '%s' "$source_id" | sha1sum | awk '{print substr($1,1,8)}')"
    max_head_length=$((MAX_STEM_LENGTH - ${#REMUX_SUFFIX} - 9))
    if [ "$max_head_length" -lt 1 ]; then
        max_head_length=1
    fi
    sanitized="${sanitized:0:max_head_length}"
    sanitized="${sanitized% }"
    if [ -z "$sanitized" ]; then
        sanitized="video"
    fi
    printf '%s-%s%s' "$sanitized" "$digest" "$REMUX_SUFFIX"
}

list_video_files() {
    find "$DATA_DIR" -maxdepth 1 -type f \( -iname '*.mkv' -o -iname '*.mp4' \) \
        ! -name '* (remux).*' | sort
}

build_remux_path() {
    local video_file="$1"
    local base_name
    local safe_stem
    local video_ext

    base_name="$(basename "${video_file%.*}")"
    video_ext="${video_file##*.}"
    safe_stem="$(normalize_for_system "$base_name" "$video_file")"
    printf '%s/%s.%s' "$(dirname "$video_file")" "$safe_stem" "$video_ext"
}

remux_output_duration() {
    local remux_file="$1"
    read_video_duration "$remux_file"
}

process_video() {
    local video_file="$1"
    local selected_dir
    local base_name
    local output_file
    local audio_file
    local original_duration
    local existing_duration

    selected_dir="$(dirname "$video_file")"
    base_name="$(basename "${video_file%.*}")"
    audio_file="$selected_dir/$base_name.pt.wav"
    output_file="$(build_remux_path "$video_file")"

    log_section "Processando video: ${video_file#$ROOT_DIR/}"
    log_step "Arquivo de audio PT: ${audio_file#$ROOT_DIR/}"
    log_step "Saida remux: ${output_file#$ROOT_DIR/}"

    if [ ! -f "$audio_file" ]; then
        log_error "Arquivo .pt.wav nao encontrado: $audio_file"
        return 1
    fi

    original_duration="$(read_video_duration "$video_file")"

    if [ -f "$output_file" ]; then
        if existing_duration="$(remux_output_duration "$output_file")" && duration_matches "$original_duration" "$existing_duration"; then
            log_step "Remux valido ja existente: ${output_file#$ROOT_DIR/}"
            return 0
        fi

        log_step "Remux existente invalido; removendo: ${output_file#$ROOT_DIR/}"
        rm -f "$output_file"
    fi

    log_section "Geracao do Remux"
    if ! ffmpeg -hide_banner -loglevel error -y \
        -i "$video_file" \
        -i "$audio_file" \
        -map 0:v:0 \
        -map 1:a:0 \
        -c:v copy \
        -c:a aac \
        -af apad \
        -t "$original_duration" \
        "$output_file"; then
        rm -f "$output_file"
        log_error "Falha ao gerar remux: $output_file"
        return 1
    fi

    if ! existing_duration="$(remux_output_duration "$output_file")" || ! duration_matches "$original_duration" "$existing_duration"; then
        log_error "Remux com duracao incompatível; removendo: ${output_file#$ROOT_DIR/}"
        rm -f "$output_file"
        return 1
    fi

    log_step "Remux gerado com sucesso: ${output_file#$ROOT_DIR/}"
    return 0
}

bootstrap_runtime

{
    if ! command -v ffmpeg >/dev/null 2>&1; then
        log_error "ffmpeg nao encontrado no PATH"
        log_summary "FALHA" "ffmpeg ausente"
        exit 1
    fi

    log_header
    log_section "Pre-requisitos"

    log_step "Config: ${CONFIG_FILE#$ROOT_DIR/}"
    log_step "Escopo de dados: ${DATA_DIR#$ROOT_DIR/}"
    log_step "Remux tolerance: $REMUX_TOLERANCE s"

    log_section "Selecao de Video"
    mapfile -t VIDEO_FILES < <(list_video_files)

    if [ "${#VIDEO_FILES[@]}" -eq 0 ]; then
        log_error "Nenhum arquivo .mkv/.mp4 encontrado em ${DATA_DIR#$ROOT_DIR/}"
        log_summary "FALHA" "Sem videos"
        exit 1
    fi

    echo ""
    echo "Videos disponiveis para remux:"
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