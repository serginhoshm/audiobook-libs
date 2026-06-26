#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG_FILE="${PIPELINE_CONFIG:-$ROOT_DIR/config/pipeline.ini}"
PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
PIPER_BIN="${PIPER_BIN:-$ROOT_DIR/bin/piper}"
MODELS_DIR="$ROOT_DIR/models"
MODEL_SIZE="${MODEL_SIZE:-medium}"
VOICE_MODEL="pt_BR-faber-medium.onnx"
RESUME_MODE="${RESUME_MODE:-1}"
ARCHIVE_ON_START="${ARCHIVE_ON_START:-0}"
TRANSCRIPTION_TOLERANCE="${TRANSCRIPTION_TOLERANCE:-5.0}"
TRANSLATION_TOLERANCE="${TRANSLATION_TOLERANCE:-0.5}"
AUDIO_TOLERANCE="${AUDIO_TOLERANCE:-1.5}"
TRANSLATION_BACKEND="${TRANSLATION_BACKEND:-google}"
NLLB_MODEL_DIR="${NLLB_MODEL_DIR:-$ROOT_DIR/models/nllb/facebook-nllb-200-distilled-600M}"
CLI_TRANSLATION_BACKEND=""
NORMALIZE_DRY_RUN=0

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
source "$ROOT_DIR/scripts/log_helpers.sh"

DATA_DIR="$ROOT_DIR/data"
DATA_SCOPE_REL="data"
ARCHIVE_ROOT="$ROOT_DIR/archive"
STATE_ROOT="$ROOT_DIR/.pipeline-state"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/exec-${TIMESTAMP}.log"
SCRIPT_NAME="Exec"
SCRIPT_START_TIME="$(date +%s)"
RUN_LOG_FILE="$LOG_DIR/exec-${TIMESTAMP}.log"

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
    ARCHIVE_ROOT="$DATA_DIR/archive"
    STATE_ROOT="$DATA_DIR/.pipeline-state"

    mkdir -p "$LOG_DIR" "$ARCHIVE_ROOT" "$STATE_ROOT"
    RUN_LOG_FILE="$LOG_DIR/exec-${TIMESTAMP}.log"
}

bootstrap_runtime() {
    if [ ! -x "$PYTHON_BIN" ]; then
        echo "ERRO: Python do ambiente virtual nao encontrado: $PYTHON_BIN" >&2
        exit 1
    fi

    if [ ! -f "$ROOT_DIR/scripts/pipeline_validators.py" ]; then
        echo "ERRO: Validador nao encontrado: $ROOT_DIR/scripts/pipeline_validators.py" >&2
        exit 1
    fi

    if ! configure_data_scope; then
        echo "ERRO: Escopo de dados invalido" >&2
        exit 1
    fi

    if ! load_pipeline_options_from_config; then
        echo "ERRO: Configuracao de pipeline invalida" >&2
        exit 1
    fi

    prepare_runtime_paths
}

load_pipeline_options_from_config() {
    local config_resume
    local config_archive

    config_resume="$(read_ini_value "$CONFIG_FILE" "pipeline" "resume_mode" "$RESUME_MODE")"
    config_archive="$(read_ini_value "$CONFIG_FILE" "pipeline" "archive_on_start" "$ARCHIVE_ON_START")"

    case "$config_resume" in
        0|1)
            RESUME_MODE="$config_resume"
            ;;
        *)
            log_error "Config invalida: pipeline.resume_mode deve ser 0 ou 1"
            return 1
            ;;
    esac

    case "$config_archive" in
        0|1)
            ARCHIVE_ON_START="$config_archive"
            ;;
        *)
            log_error "Config invalida: pipeline.archive_on_start deve ser 0 ou 1"
            return 1
            ;;
    esac

    return 0
}

list_video_files() {
    if [[ "$DATA_DIR" = "$ROOT_DIR/data" || "$DATA_DIR" = "$ROOT_DIR/data/"* ]]; then
        find "$DATA_DIR" -type f \( -iname '*.mkv' -o -iname '*.mp4' \) \
            ! -path "$ROOT_DIR/data/saved/*" | sort
    else
        find "$DATA_DIR" -type f \( -iname '*.mkv' -o -iname '*.mp4' \) | sort
    fi
}

state_file_for_video() {
    local video_file="$1"
    local state_id
    state_id="$(printf '%s|%s' "$DATA_SCOPE_REL" "$video_file" | sha1sum | awk '{print $1}')"
    printf '%s/%s.state' "$STATE_ROOT" "$state_id"
}

state_set() {
    local state_file="$1"
    local state_key="$2"
    local state_value="$3"
    local tmp_file

    mkdir -p "$STATE_ROOT"
    touch "$state_file"
    tmp_file="$(mktemp)"
    awk -F '\t' -v k="$state_key" '$1 != k { print }' "$state_file" > "$tmp_file"
    printf '%s\t%s\n' "$state_key" "$state_value" >> "$tmp_file"
    mv "$tmp_file" "$state_file"
}

video_log_file_for() {
    local video_file="$1"
    local preview_file
    local preview_base_name

    preview_file="$($PYTHON_BIN -u "$ROOT_DIR/scripts/renomear-arquivos.py" \
        --root-dir "$ROOT_DIR" \
        --data-root "$DATA_DIR" \
        --archive-root "$ARCHIVE_ROOT" \
        --state-root "$STATE_ROOT" \
        --logs-dir "$LOG_DIR" \
        --scope-rel "$DATA_SCOPE_REL" \
        --preview \
        --video "$video_file")"

    if [ -z "$preview_file" ]; then
        return 1
    fi

    preview_base_name="$(basename "${preview_file%.*}")"
    if [ -z "$preview_base_name" ]; then
        return 1
    fi
    printf '%s/exec-%s-%s.log' "$LOG_DIR" "$TIMESTAMP" "$preview_base_name"
}

update_step_state() {
    local state_file="$1"
    local step_name="$2"
    local step_status="$3"
    local detail="$4"
    state_set "$state_file" "${step_name}_status" "$step_status"
    state_set "$state_file" "${step_name}_updated_at" "$(date -Iseconds)"
    state_set "$state_file" "${step_name}_detail" "$detail"
}

validator_command() {
    "$PYTHON_BIN" "$ROOT_DIR/scripts/pipeline_validators.py" "$@"
}

validate_existing_media() {
    local media_file="$1"
    validator_command media-duration --input "$media_file" >/dev/null 2>&1
}

validate_transcription_ready() {
    local audio_file="$1"
    local srt_file="$2"
    validator_command validate-transcription \
        --audio "$audio_file" \
        --srt "$srt_file" \
        --tolerance "$TRANSCRIPTION_TOLERANCE" >/dev/null 2>&1
}

validate_translation_ready() {
    local source_srt="$1"
    local translated_srt="$2"
    validator_command validate-translation \
        --source-srt "$source_srt" \
        --target-srt "$translated_srt" \
        --tolerance "$TRANSLATION_TOLERANCE" >/dev/null 2>&1
}

validate_audio_ready() {
    local source_srt="$1"
    local output_audio="$2"
    validator_command validate-generated-audio \
        --srt "$source_srt" \
        --audio "$output_audio" \
        --tolerance "$AUDIO_TOLERANCE" >/dev/null 2>&1
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

infer_translation_lang_from_name() {
    local name_lower
    name_lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$name_lower" in
        *_spanish*|*spanish*)
            printf 'es'
            ;;
        *_chinese*|*chinese*)
            printf 'zh-CN'
            ;;
        *)
            printf 'auto'
            ;;
    esac
}

infer_translation_lang_from_srt() {
    local srt_file="$1"

    if [ ! -f "$srt_file" ]; then
        printf 'auto'
        return 0
    fi

    "$PYTHON_BIN" - "$srt_file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="ignore")

han_count = len(re.findall(r"[\u3400-\u9fff\uf900-\ufaff]", text))
es_hint_count = len(
    re.findall(
        r"\b(el|la|los|las|de|que|por|para|con|una|uno|como|pero|est[aá]|est[aá]n|hoy)\b|[¿¡ñáéíóúü]",
        text.lower(),
    )
)

if han_count >= 15 and han_count >= (es_hint_count * 0.6):
    print("zh-CN")
elif es_hint_count >= 20:
    print("es")
else:
    print("auto")
PY
}

translation_lang_suffix() {
    case "$1" in
        zh-CN)
            printf 'chinese'
            ;;
        es)
            printf 'spanish'
            ;;
        *)
            printf ''
            ;;
    esac
}

display_lang_tag() {
    case "$1" in
        es)
            printf 'spanish'
            ;;
        zh-CN)
            printf 'chinese'
            ;;
        *)
            printf 'auto'
            ;;
    esac
}

video_size_gb() {
    local video_file="$1"
    local size_bytes

    if [ ! -f "$video_file" ]; then
        printf '0.00'
        return 0
    fi

    size_bytes="$(stat -c%s "$video_file" 2>/dev/null || echo 0)"
    awk -v bytes="$size_bytes" 'BEGIN { printf "%.2f", (bytes / 1024 / 1024 / 1024) }'
}

infer_original_lang_for_video() {
    local video_file="$1"
    local dir
    local stem
    local candidate_srt
    local inferred

    dir="$(dirname "$video_file")"
    stem="$(basename "${video_file%.*}")"

    for candidate_srt in \
        "$dir/$stem.srt" \
        "$dir/${stem}_spanish.srt" \
        "$dir/${stem}_chinese.srt"
    do
        if [ -f "$candidate_srt" ]; then
            inferred="$(infer_translation_lang_from_srt "$candidate_srt")"
            if [ "$inferred" != "auto" ]; then
                printf '%s' "$inferred"
                return 0
            fi
        fi
    done

    infer_translation_lang_from_name "$stem"
}

normalize_video_file() {
    local video_file="$1"
    local lang_suffix="$2"
    local preview_only="${3:-0}"
    local normalized
    local cmd

    cmd=(
        "$PYTHON_BIN" -u "$ROOT_DIR/scripts/renomear-arquivos.py"
        --root-dir "$ROOT_DIR"
        --data-root "$DATA_DIR"
        --archive-root "$ARCHIVE_ROOT"
        --state-root "$STATE_ROOT"
        --logs-dir "$LOG_DIR"
        --scope-rel "$DATA_SCOPE_REL"
        --video "$video_file"
    )

    if [ -n "$lang_suffix" ]; then
        cmd+=(--lang-suffix "$lang_suffix")
    fi

    if [ "$preview_only" = "1" ]; then
        cmd+=(--preview)
    fi

    normalized="$("${cmd[@]}")"
    printf '%s' "$normalized"
}

rename_artifacts_with_base() {
    local dir="$1"
    local old_base="$2"
    local new_base="$3"
    local old_path
    local new_path

    if [ "$old_base" = "$new_base" ]; then
        return 0
    fi

    for ext in \
        ".json" \
        ".srt" \
        ".tsv" \
        ".txt" \
        ".vtt" \
        ".pt.srt" \
        ".pt.wav"
    do
        old_path="$dir/$old_base$ext"
        new_path="$dir/$new_base$ext"
        if [ -f "$old_path" ] && [ ! -f "$new_path" ]; then
            mv -f "$old_path" "$new_path"
        fi
    done
}

print_usage() {
    cat <<'EOF'
Uso: workflows/exec.sh [opcoes]

Opcoes:
  --backend <google|nllb_local>   Define backend de traducao sem prompt interativo.
    --normalize-dry-run             Simula apenas a normalizacao inicial e encerra.
  --help                          Exibe esta ajuda.
EOF
}

parse_cli_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --backend)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "Parametro --backend exige um valor."
                    print_usage
                    return 1
                fi
                CLI_TRANSLATION_BACKEND="$1"
                ;;
            --backend=*)
                CLI_TRANSLATION_BACKEND="${1#*=}"
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            --normalize-dry-run)
                NORMALIZE_DRY_RUN=1
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

select_translation_backend() {
    local choice
    local default_choice

    if [ -n "$CLI_TRANSLATION_BACKEND" ]; then
        case "$CLI_TRANSLATION_BACKEND" in
            google)
                TRANSLATION_BACKEND="google"
                ;;
            nllb_local)
                TRANSLATION_BACKEND="nllb_local"
                ;;
            *)
                log_error "Backend invalido via --backend: $CLI_TRANSLATION_BACKEND"
                return 1
                ;;
        esac
        log_step "Backend de traducao definido por CLI: $TRANSLATION_BACKEND"
    fi

    case "$TRANSLATION_BACKEND" in
        nllb_local)
            default_choice="2"
            ;;
        google)
            default_choice="1"
            ;;
        *)
            TRANSLATION_BACKEND="google"
            default_choice="1"
            ;;
    esac

    if [ -z "$CLI_TRANSLATION_BACKEND" ]; then
        echo ""
        echo "Backend de traducao disponivel:"
        echo "  1) google (online, padrao)"
        echo "  2) nllb_local (offline)"
        echo ""

        read -r -p "Selecione backend de traducao [1/2] (padrao: ${default_choice}): " choice
        choice="${choice:-$default_choice}"

        case "$choice" in
            1|google|GOOGLE|Google)
                TRANSLATION_BACKEND="google"
                ;;
            2|nllb_local|NLLB_LOCAL|nllb|NLLB)
                TRANSLATION_BACKEND="nllb_local"
                ;;
            *)
                log_error "Selecao de backend invalida: $choice"
                return 1
                ;;
        esac
    fi

    if [ "$TRANSLATION_BACKEND" = "nllb_local" ] && [ ! -d "$NLLB_MODEL_DIR" ]; then
        log_error "Modelo NLLB local nao encontrado: $NLLB_MODEL_DIR"
        log_step "Dica: execute setup/setup-nllb-local.sh para instalar o modelo."
        return 1
    fi

    log_step "Backend de traducao selecionado: $TRANSLATION_BACKEND"
    if [ "$TRANSLATION_BACKEND" = "nllb_local" ]; then
        log_step "Diretorio do modelo NLLB: ${NLLB_MODEL_DIR#$ROOT_DIR/}"
    fi

    return 0
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

    if [[ "$source_dir" = "$ROOT_DIR/data" ]]; then
        rel_dir="root"
    elif [[ "$source_dir" = "$ROOT_DIR/data/"* ]]; then
        rel_dir="${source_dir#$ROOT_DIR/data/}"
    else
        rel_dir="external/$(printf '%s' "$source_dir" | sed -e 's#^/##' -e 's#[^A-Za-z0-9._/-]#_#g')"
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
    local state_file
    local video_log_file

    if [ "$ARCHIVE_ON_START" = "1" ]; then
        log_section "Limpeza por Arquivamento"
        archive_previous_outputs "$original_video_file"
    else
        log_step "Arquivamento automatico desabilitado (ARCHIVE_ON_START=0)"
    fi

    selected_dir="$(dirname "$video_file")"
    base_name="$(basename "${video_file%.*}")"
    video_log_file="$LOG_DIR/exec-${base_name}-${TIMESTAMP}.log"
    LOG_FILE="$video_log_file"
    audio_wav="$selected_dir/$base_name.wav"
    output_srt="$selected_dir/$base_name.srt"
    output_pt_srt="$selected_dir/$base_name.pt.srt"
    output_pt_wav="$selected_dir/$base_name.pt.wav"
    state_file="$(state_file_for_video "$video_file")"

    whisper_lang="auto"
    source_lang="auto"

    state_set "$state_file" "input_video" "$video_file"
    state_set "$state_file" "scope" "$DATA_SCOPE_REL"
    state_set "$state_file" "audio_wav" "$audio_wav"
    state_set "$state_file" "output_srt" "$output_srt"
    state_set "$state_file" "output_pt_srt" "$output_pt_srt"
    state_set "$state_file" "output_pt_wav" "$output_pt_wav"
    state_set "$state_file" "last_run" "$(date -Iseconds)"

    log_section "Processando video: ${video_file#$ROOT_DIR/}"
    log_step "Idioma transcricao: $whisper_lang (deteccao automatica)"
    log_step "State file: ${state_file#$ROOT_DIR/}"

    if [ "$RUN_LOG_FILE" != "$video_log_file" ]; then
        log_step "Log do video: ${video_log_file#$ROOT_DIR/}"
    fi

    log_section "Etapa 0 - Extracao de Audio"
    if [ "$RESUME_MODE" = "1" ] && [ -f "$audio_wav" ] && validate_existing_media "$audio_wav"; then
        update_step_state "$state_file" "extract" "success" "reutilizado"
        log_step "WAV reutilizado: ${audio_wav#$ROOT_DIR/}"
    else
        update_step_state "$state_file" "extract" "running" "extraindo WAV"
        if ! ffmpeg -hide_banner -loglevel error -i "$video_file" -vn "$audio_wav"; then
            update_step_state "$state_file" "extract" "failed" "ffmpeg falhou"
            log_error "Falha ao gerar WAV: $audio_wav"
            return 1
        fi
        if [ ! -f "$audio_wav" ] || ! validate_existing_media "$audio_wav"; then
            update_step_state "$state_file" "extract" "failed" "WAV ausente ou invalido"
            log_error "Falha ao gerar WAV valido: $audio_wav"
            return 1
        fi
        update_step_state "$state_file" "extract" "success" "WAV gerado"
        log_step "WAV gerado: ${audio_wav#$ROOT_DIR/}"
    fi

    log_section "Etapa 1 - Transcricao"
    if [ "$RESUME_MODE" = "1" ] && validate_transcription_ready "$audio_wav" "$output_srt"; then
        update_step_state "$state_file" "transcribe" "success" "reutilizado"
        log_step "Transcricao valida ja existente: ${output_srt#$ROOT_DIR/}"
    else
        update_step_state "$state_file" "transcribe" "running" "transcrevendo"
        "$PYTHON_BIN" -u "$ROOT_DIR/scripts/transcrever.py" \
            "$audio_wav" \
            "$selected_dir" \
            "$whisper_lang" \
            "$MODEL_SIZE" \
            "$base_name"

        if ! validate_transcription_ready "$audio_wav" "$output_srt"; then
            update_step_state "$state_file" "transcribe" "failed" "SRT nao validado"
            log_error "SRT nao gerado/validado: $output_srt"
            return 1
        fi
        update_step_state "$state_file" "transcribe" "success" "SRT validado"
        log_step "Transcricao gerada: ${output_srt#$ROOT_DIR/}"
    fi

    source_lang="$(infer_translation_lang_from_srt "$output_srt")"
    if [ "$source_lang" = "auto" ]; then
        source_lang="$(infer_translation_lang_from_name "$base_name")"
    fi

    state_set "$state_file" "source_lang" "$source_lang"
    log_step "Idioma traducao inferido pelo SRT: $source_lang"

    log_section "Etapa 2 - Traducao"
    if [ "$RESUME_MODE" = "1" ] && validate_translation_ready "$output_srt" "$output_pt_srt"; then
        update_step_state "$state_file" "translate" "success" "reutilizado"
        log_step "Traducao valida ja existente: ${output_pt_srt#$ROOT_DIR/}"
    else
        update_step_state "$state_file" "translate" "running" "traduzindo"
        "$PYTHON_BIN" "$ROOT_DIR/scripts/traduzir.py" \
            "$output_srt" \
            "$output_pt_srt" \
            "$source_lang" \
            --backend "$TRANSLATION_BACKEND" \
            --nllb-model-dir "$NLLB_MODEL_DIR"

        if ! validate_translation_ready "$output_srt" "$output_pt_srt"; then
            update_step_state "$state_file" "translate" "failed" "SRT traduzido nao validado"
            log_error "SRT traduzido nao gerado/validado: $output_pt_srt"
            return 1
        fi
        update_step_state "$state_file" "translate" "success" "SRT traduzido validado"
        log_step "Traducao gerada: ${output_pt_srt#$ROOT_DIR/}"
    fi

    log_section "Etapa 3 - Geracao de Audiobook"
    if [ "$RESUME_MODE" = "1" ] && validate_audio_ready "$output_pt_srt" "$output_pt_wav"; then
        update_step_state "$state_file" "audiobook" "success" "reutilizado"
        log_step "Audiobook valido ja existente: ${output_pt_wav#$ROOT_DIR/}"
    else
        update_step_state "$state_file" "audiobook" "running" "gerando audio"
        "$PYTHON_BIN" -u "$ROOT_DIR/scripts/gerar-sincronizado.py" \
            --srt "$output_pt_srt" \
            --output "$output_pt_wav" \
            --model "$MODELS_DIR/$VOICE_MODEL" \
            --piper "$PIPER_BIN" \
            --source_lang "$source_lang" \
            --pause_duration 0.1

        if ! validate_audio_ready "$output_pt_srt" "$output_pt_wav"; then
            update_step_state "$state_file" "audiobook" "failed" "audio final nao validado"
            log_error "Audio final nao gerado/validado: $output_pt_wav"
            return 1
        fi
        update_step_state "$state_file" "audiobook" "success" "audio validado"
        log_step "Audiobook gerado: ${output_pt_wav#$ROOT_DIR/}"
    fi

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

    log_header
    log_section "Pre-requisitos"

    log_step "Config: ${CONFIG_FILE#$ROOT_DIR/}"
    log_step "Escopo de dados: ${DATA_DIR#$ROOT_DIR/}"
    log_step "Resume mode: $RESUME_MODE"
    log_step "Archive on start: $ARCHIVE_ON_START"
    if [ "$NORMALIZE_DRY_RUN" = "1" ]; then
        log_step "Normalize dry-run: habilitado"
    fi

    log_section "Selecao de Backend de Traducao"
    if ! select_translation_backend; then
        log_summary "FALHA" "Selecao de backend invalida"
        exit 1
    fi

    log_section "Normalizando lista de arquivos"
    mapfile -t VIDEO_FILES < <(list_video_files)

    if [ "${#VIDEO_FILES[@]}" -eq 0 ]; then
        log_error "Nenhum arquivo .mkv/.mp4 encontrado em ${DATA_DIR#$ROOT_DIR/}"
        log_summary "FALHA" "Sem videos"
        exit 1
    fi

    NORMALIZED_VIDEO_FILES=()
    NORMALIZED_VIDEO_LANGS=()
    for video in "${VIDEO_FILES[@]}"; do
        inferred_source_lang="$(infer_original_lang_for_video "$video")"
        inferred_lang_suffix="$(translation_lang_suffix "$inferred_source_lang")"
        normalized_video="$(normalize_video_file "$video" "$inferred_lang_suffix" "$NORMALIZE_DRY_RUN")"

        if [ -z "$normalized_video" ]; then
            log_error "Falha ao normalizar video: ${video#$ROOT_DIR/}"
            continue
        fi

        if [ "$video" != "$normalized_video" ]; then
            log_step "Normalizado: ${video#$ROOT_DIR/} -> ${normalized_video#$ROOT_DIR/}"
        else
            log_step "Sem mudanca: ${video#$ROOT_DIR/}"
        fi

        if [ -n "$inferred_lang_suffix" ]; then
            log_step "Idioma original inferido: $inferred_source_lang (_${inferred_lang_suffix})"
        else
            log_step "Idioma original inferido: auto (sem sufixo)"
        fi

        NORMALIZED_VIDEO_FILES+=("$normalized_video")
        NORMALIZED_VIDEO_LANGS+=("$inferred_source_lang")
    done

    VIDEO_FILES=("${NORMALIZED_VIDEO_FILES[@]}")
    VIDEO_LANGS=("${NORMALIZED_VIDEO_LANGS[@]}")
    if [ "${#VIDEO_FILES[@]}" -eq 0 ]; then
        log_error "Nenhum video disponivel apos normalizacao"
        log_summary "FALHA" "Normalizacao sem videos"
        exit 1
    fi

    if [ "$NORMALIZE_DRY_RUN" = "1" ]; then
        log_section "Dry-run concluido"
        log_step "Nenhum arquivo foi alterado."
        log_summary "SUCCESS" "Dry-run de normalizacao"
        exit 0
    fi

    ORDERED_VIDEO_FILES=()
    ORDERED_VIDEO_LANGS=()
    for group in spanish chinese auto; do
        for idx in "${!VIDEO_FILES[@]}"; do
            lang_tag="$(display_lang_tag "${VIDEO_LANGS[$idx]:-auto}")"
            if [ "$lang_tag" = "$group" ]; then
                ORDERED_VIDEO_FILES+=("${VIDEO_FILES[$idx]}")
                ORDERED_VIDEO_LANGS+=("${VIDEO_LANGS[$idx]}")
            fi
        done
    done

    VIDEO_FILES=("${ORDERED_VIDEO_FILES[@]}")
    VIDEO_LANGS=("${ORDERED_VIDEO_LANGS[@]}")

    log_section "Selecao de Video"

    echo ""
    echo "Videos disponiveis para processamento:"
    i=1
    current_group=""
    for idx in "${!VIDEO_FILES[@]}"; do
        video="${VIDEO_FILES[$idx]}"
        lang_tag="$(display_lang_tag "${VIDEO_LANGS[$idx]:-auto}")"
        if [ "$lang_tag" != "$current_group" ]; then
            echo "  ${lang_tag}:"
            current_group="$lang_tag"
        fi
        file_name="$(basename "$video")"
        size_gb="$(video_size_gb "$video")"
        echo "    $i) ${lang_tag} | ${size_gb}GB: ${file_name}"
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
        if ! selected_video_log="$(video_log_file_for "$selected_video")"; then
            log_error "Nao foi possivel criar log para: $selected_video"
            fail_count=$((fail_count + 1))
            continue
        fi
        LOG_FILE="$selected_video_log"
        if process_video "$selected_video" 2>&1 | tee -a "$selected_video_log"; then
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
} 2>&1 | tee -a "$RUN_LOG_FILE"
