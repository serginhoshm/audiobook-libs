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
    local original_video_file
    local original_base_name
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
    local selected_video_log

    original_video_file="$video_file"
    original_base_name="$(basename "${original_video_file%.*}")"

    if [ "$ARCHIVE_ON_START" = "1" ]; then
        log_section "Limpeza por Arquivamento"
        archive_previous_outputs "$original_video_file"
    else
        log_step "Arquivamento automatico desabilitado (ARCHIVE_ON_START=0)"
    fi

    video_file="$($PYTHON_BIN -u "$ROOT_DIR/scripts/renomear-arquivos.py" \
        --root-dir "$ROOT_DIR" \
        --data-root "$DATA_DIR" \
        --archive-root "$ARCHIVE_ROOT" \
        --state-root "$STATE_ROOT" \
        --logs-dir "$LOG_DIR" \
        --scope-rel "$DATA_SCOPE_REL" \
        --video "$original_video_file")"

    if [ -z "$video_file" ]; then
        log_error "Falha ao normalizar o nome do video: $original_video_file"
        return 1
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

    whisper_lang="$(infer_whisper_lang "$original_base_name")"
    source_lang="$(infer_translation_lang "$whisper_lang")"

    state_set "$state_file" "input_video" "$video_file"
    state_set "$state_file" "scope" "$DATA_SCOPE_REL"
    state_set "$state_file" "audio_wav" "$audio_wav"
    state_set "$state_file" "output_srt" "$output_srt"
    state_set "$state_file" "output_pt_srt" "$output_pt_srt"
    state_set "$state_file" "output_pt_wav" "$output_pt_wav"
    state_set "$state_file" "last_run" "$(date -Iseconds)"

    log_section "Processando video: ${video_file#$ROOT_DIR/}"
    if [ "$original_video_file" != "$video_file" ]; then
        log_step "Nome normalizado: ${original_video_file#$ROOT_DIR/} -> ${video_file#$ROOT_DIR/}"
    fi
    log_step "Idioma transcricao: $whisper_lang"
    log_step "Idioma traducao: $source_lang"
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

    log_section "Etapa 2 - Traducao"
    if [ "$RESUME_MODE" = "1" ] && validate_translation_ready "$output_srt" "$output_pt_srt"; then
        update_step_state "$state_file" "translate" "success" "reutilizado"
        log_step "Traducao valida ja existente: ${output_pt_srt#$ROOT_DIR/}"
    else
        update_step_state "$state_file" "translate" "running" "traduzindo"
        "$PYTHON_BIN" "$ROOT_DIR/scripts/traduzir.py" \
            "$output_srt" \
            "$output_pt_srt" \
            "$source_lang"

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

    log_section "Selecao de Video"
    mapfile -t VIDEO_FILES < <(list_video_files)

    if [ "${#VIDEO_FILES[@]}" -eq 0 ]; then
        log_error "Nenhum arquivo .mkv/.mp4 encontrado em ${DATA_DIR#$ROOT_DIR/}"
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
