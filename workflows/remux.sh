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
WORK_EXEC_DIR="$DATA_DIR/exec"
DONE_DIR="$DATA_DIR/done"
PUBLISHED_DIR="$DATA_DIR/published"
REMUX_DIR="$DATA_DIR/remux"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/remux-${TIMESTAMP}.log"
SCRIPT_NAME="Remux"
SCRIPT_START_TIME="$(date +%s)"

MAX_STEM_LENGTH=120
REMUX_SUFFIX=" (remux)"
REMUX_TOLERANCE="${REMUX_TOLERANCE:-0.5}"
FFMPEG_MODE="${FFMPEG_MODE:-normal}"
CLI_FFMPEG_MODE=""

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

    mkdir -p "$scope_abs"

    if [ ! -r "$scope_abs" ] || [ ! -w "$scope_abs" ]; then
        log_error "Sem permissao de leitura/escrita no escopo: $scope_abs"
        return 1
    fi

    DATA_SCOPE_REL="$configured_path"
    DATA_DIR="$scope_abs"
    return 0
}

ensure_data_subdirs() {
    WORK_EXEC_DIR="$DATA_DIR/exec"
    DONE_DIR="$DATA_DIR/done"
    PUBLISHED_DIR="$DATA_DIR/published"
    REMUX_DIR="$DATA_DIR/remux"

    mkdir -p "$WORK_EXEC_DIR" "$DONE_DIR" "$PUBLISHED_DIR" "$REMUX_DIR"
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

    ensure_data_subdirs

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

print_usage() {
    cat <<'EOF'
Uso: workflows/remux.sh [opcoes]

Opcoes:
    --ffmpeg-mode <normal|cuda>    Define o modo do FFmpeg sem prompt interativo.
    --ffmpeg-mode=normal|cuda      Forma abreviada da opcao acima.
    --help                         Exibe esta ajuda.
EOF
}

parse_cli_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --ffmpeg-mode)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "Parametro --ffmpeg-mode exige um valor (normal/cuda)."
                    print_usage
                    return 1
                fi
                CLI_FFMPEG_MODE="$1"
                ;;
            --ffmpeg-mode=*)
                CLI_FFMPEG_MODE="${1#*=}"
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                log_error "Opcao desconhecida: $1"
                print_usage
                return 1
                ;;
        esac
        shift
    done

    return 0
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
    find "$DONE_DIR" -maxdepth 1 -type f \( -iname '*.mkv' -o -iname '*.mp4' \) \
        ! -name '* (remux).*' | sort
}

build_remux_dest_path() {
    local video_file="$1"
    local output_file

    output_file="$(build_remux_path "$video_file")"
    printf '%s/%s' "$REMUX_DIR" "$(basename "$output_file")"
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

detect_video_codec() {
    local media_file="$1"

    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$media_file" | head -n 1
}

cuda_encoder_for_codec() {
    local codec_name="$1"

    case "$codec_name" in
        h264|avc1)
            printf '%s' "h264_nvenc"
            ;;
        hevc|h265)
            printf '%s' "hevc_nvenc"
            ;;
        *)
            printf ''
            ;;
    esac
}

run_ffmpeg_with_progress() {
    local total_duration="$1"
    shift

    local -a ffmpeg_cmd=("$@")
    local last_bucket=-10
    local progress_seconds
    local percent
    local bucket

    "${ffmpeg_cmd[@]}" -progress pipe:1 -nostats -loglevel error |
        while IFS='=' read -r key value; do
            case "$key" in
                out_time_ms)
                    if [[ "$total_duration" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                        progress_seconds="$(awk -v ms="$value" 'BEGIN { printf "%.3f", ms / 1000000 }')"
                        percent="$(awk -v current="$progress_seconds" -v total="$total_duration" 'BEGIN { if (total <= 0) { print 0; exit } pct = int((current / total) * 100); if (pct > 100) pct = 100; print pct }')"
                        bucket=$((percent / 10 * 10))
                        if [ "$bucket" -gt "$last_bucket" ]; then
                            last_bucket="$bucket"
                            log_step "Progresso FFmpeg: ${bucket}%"
                        fi
                    fi
                    ;;
                progress)
                    if [ "$value" = "end" ]; then
                        log_step "Progresso FFmpeg: 100%"
                    fi
                    ;;
            esac
        done
}

select_ffmpeg_mode() {
    local choice

    if [ -n "$CLI_FFMPEG_MODE" ]; then
        case "$CLI_FFMPEG_MODE" in
            normal|NORMAL|Normal|cpu|CPU|0|off|OFF|false|FALSE)
                FFMPEG_MODE="normal"
                ;;
            cuda|CUDA|Cuda|gpu|GPU|1|on|ON|true|TRUE)
                FFMPEG_MODE="cuda"
                ;;
            *)
                log_error "--ffmpeg-mode invalido: $CLI_FFMPEG_MODE (use normal/cuda)"
                return 1
                ;;
        esac
        log_step "FFmpeg definido por CLI: $FFMPEG_MODE"
    else
        echo ""
        echo "Modo do FFmpeg no remux:"
        echo "  1) Normal (padrao)"
        echo "  2) CUDA (GPU)"
        echo ""
        read -r -p "Usar FFmpeg com CUDA? [1/2] (padrao: 1): " choice
        choice="${choice:-1}"
        case "$choice" in
            1|normal|NORMAL|cpu|CPU)
                FFMPEG_MODE="normal"
                ;;
            2|cuda|CUDA|Cuda|gpu|GPU)
                FFMPEG_MODE="cuda"
                ;;
            *)
                log_error "Selecao de modo do FFmpeg invalida: $choice"
                return 1
                ;;
        esac
    fi

    if [ "$FFMPEG_MODE" = "cuda" ]; then
        log_step "FFmpeg CUDA: habilitado"
    else
        log_step "FFmpeg CUDA: desabilitado (normal)"
    fi

    return 0
}

process_video() {
    local video_file="$1"
    local selected_dir
    local base_name
    local output_file
    local remux_dest_file
    local audio_file
    local original_duration
    local existing_duration
    local video_codec
    local ffmpeg_video_codec

    selected_dir="$(dirname "$video_file")"
    base_name="$(basename "${video_file%.*}")"
    audio_file="$selected_dir/$base_name.pt.wav"
    output_file="$(build_remux_path "$video_file")"
    remux_dest_file="$(build_remux_dest_path "$video_file")"

    log_section "Processando video: ${video_file#$ROOT_DIR/}"
    log_step "Arquivo de audio PT: ${audio_file#$ROOT_DIR/}"
    log_step "Saida temporaria remux: ${output_file#$ROOT_DIR/}"
    log_step "Saida final remux: ${remux_dest_file#$ROOT_DIR/}"

    if [ ! -f "$audio_file" ]; then
        log_error "Arquivo .pt.wav nao encontrado: $audio_file"
        return 1
    fi

    original_duration="$(read_video_duration "$video_file")"

    if [ -f "$remux_dest_file" ]; then
        if existing_duration="$(remux_output_duration "$remux_dest_file")" && duration_matches "$original_duration" "$existing_duration"; then
            log_step "Remux valido ja existente: ${remux_dest_file#$ROOT_DIR/}"
            return 0
        fi

        log_step "Remux final existente invalido; removendo: ${remux_dest_file#$ROOT_DIR/}"
        rm -f "$remux_dest_file"
    fi

    if [ -f "$output_file" ]; then
        if existing_duration="$(remux_output_duration "$output_file")" && duration_matches "$original_duration" "$existing_duration"; then
            mv -f "$output_file" "$remux_dest_file"
            log_step "Remux ja existente movido para destino final: ${remux_dest_file#$ROOT_DIR/}"
            return 0
        fi

        log_step "Remux existente invalido; removendo: ${output_file#$ROOT_DIR/}"
        rm -f "$output_file"
    fi

    log_section "Geracao do Remux"
    local -a ffmpeg_cmd=(ffmpeg -hide_banner -loglevel error -y)
    ffmpeg_video_codec="copy"

    if [ "$FFMPEG_MODE" = "cuda" ]; then
        video_codec="$(detect_video_codec "$video_file")"
        ffmpeg_video_codec="$(cuda_encoder_for_codec "$video_codec")"
        if [ -z "$ffmpeg_video_codec" ]; then
            log_step "Codec de video nao suportado para CUDA: ${video_codec:-desconhecido}; mantendo modo normal"
            FFMPEG_MODE="normal"
        else
            log_step "Codec de video detectado: $video_codec -> encoder CUDA: $ffmpeg_video_codec"
            ffmpeg_cmd+=(-hwaccel cuda -hwaccel_output_format cuda)
        fi
    fi

    if [ "$FFMPEG_MODE" = "normal" ]; then
        ffmpeg_video_codec="copy"
    fi

    ffmpeg_cmd+=(
        -i "$video_file"
        -i "$audio_file"
        -map 0:v:0
        -map 1:a:0
        -c:v "$ffmpeg_video_codec"
        -c:a aac
        -af apad
        -t "$original_duration"
        "$output_file"
    )

    if ! run_ffmpeg_with_progress "$original_duration" "${ffmpeg_cmd[@]}"; then
        rm -f "$output_file"
        log_error "Falha ao gerar remux: $output_file"
        return 1
    fi

    if ! existing_duration="$(remux_output_duration "$output_file")" || ! duration_matches "$original_duration" "$existing_duration"; then
        log_error "Remux com duracao incompatível; removendo: ${output_file#$ROOT_DIR/}"
        rm -f "$output_file"
        return 1
    fi

    mv -f "$output_file" "$remux_dest_file"
    log_step "Remux gerado com sucesso: ${remux_dest_file#$ROOT_DIR/}"
    return 0
}

if ! parse_cli_args "$@"; then
    exit 1
fi

bootstrap_runtime

{
    if ! command -v ffmpeg >/dev/null 2>&1; then
        log_error "ffmpeg nao encontrado no PATH"
        log_summary "FALHA" "ffmpeg ausente"
        exit 1
    fi

    if ! command -v ffprobe >/dev/null 2>&1; then
        log_error "ffprobe nao encontrado no PATH"
        log_summary "FALHA" "ffprobe ausente"
        exit 1
    fi

    log_header
    log_section "Pre-requisitos"

    log_step "Config: ${CONFIG_FILE#$ROOT_DIR/}"
    log_step "Escopo de dados: ${DATA_DIR#$ROOT_DIR/}"
    log_step "Entrada de remux (done): ${DONE_DIR#$ROOT_DIR/}"
    log_step "Saida de remux: ${REMUX_DIR#$ROOT_DIR/}"
    log_step "Remux tolerance: $REMUX_TOLERANCE s"

    if ! select_ffmpeg_mode; then
        log_summary "FALHA" "Selecao do FFmpeg invalida"
        exit 1
    fi

    log_section "Selecao de Video"
    mapfile -t VIDEO_FILES < <(list_video_files)

    if [ "${#VIDEO_FILES[@]}" -eq 0 ]; then
        log_error "Nenhum arquivo .mkv/.mp4 encontrado em ${DONE_DIR#$ROOT_DIR/}"
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