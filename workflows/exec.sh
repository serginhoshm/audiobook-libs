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
DEEPL_CONFIG_FILE="${DEEPL_CONFIG_FILE:-$ROOT_DIR/config/translation/deepl.env}"
DEEPL_KEYS_INI="${DEEPL_KEYS_INI:-$ROOT_DIR/config/translation/deepl_keys.ini}"
DEEPL_KEYS_STATE_INI="${DEEPL_KEYS_STATE_INI:-$ROOT_DIR/config/translation/deepl_keys_state.ini}"
GEMINI_CONFIG_FILE="${GEMINI_CONFIG_FILE:-$ROOT_DIR/config/translation/gemini.env}"
GEMINI_MODEL="${GEMINI_MODEL:-gemini-1.5-flash}"
DEEPL_ENDPOINT="${DEEPL_ENDPOINT:-free}"
DEEPL_BASE="${DEEPL_BASE:-}"
NLLB_MAX_INPUT_LENGTH="${NLLB_MAX_INPUT_LENGTH:-768}"
NLLB_MAX_NEW_TOKENS="${NLLB_MAX_NEW_TOKENS:-192}"
NLLB_USE_GPU="${NLLB_USE_GPU:-1}"
NLLB_LEGACY_GENERATION="${NLLB_LEGACY_GENERATION:-0}"
WHISPER_USE_CUDA="${WHISPER_USE_CUDA:-0}"
PIPER_USE_CUDA="${PIPER_USE_CUDA:-0}"
CLI_TRANSLATION_BACKEND=""
CLI_NLLB_PROFILE=""
CLI_NLLB_MAX_INPUT_LENGTH=""
CLI_NLLB_MAX_NEW_TOKENS=""
CLI_NLLB_USE_GPU=""
CLI_NLLB_LEGACY_GENERATION=""
CLI_DEEPL_ENDPOINT=""
CLI_RESET_DEEPL_KEYS_STATE="0"
CLI_WHISPER_CUDA=""
CLI_PIPER_CUDA=""

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
source "$ROOT_DIR/scripts/log_helpers.sh"

DATA_DIR="$ROOT_DIR/data"
DATA_SCOPE_REL="data"
WORK_EXEC_DIR="$DATA_DIR/exec"
DONE_DIR="$DATA_DIR/done"
PUBLISHED_DIR="$DATA_DIR/published"
REMUX_DIR="$DATA_DIR/remux"
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

    ensure_data_subdirs

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
    find "$WORK_EXEC_DIR" -maxdepth 1 -type f \( -iname '*.mkv' -o -iname '*.mp4' \) | sort
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

print_usage() {
    cat <<'EOF'
Uso: workflows/exec.sh [opcoes]

Opcoes:
    --backend <google|nllb_local|deepl_doc|gemini>
                                                                    Define backend de traducao sem prompt interativo.
    --nllb-profile <fast|legacy|custom>
                                                                    Perfil NLLB sem prompt interativo.
    --nllb-max-input-length <N>     Override de max_input_length do NLLB.
    --nllb-max-new-tokens <N>       Override de max_new_tokens do NLLB.
    --nllb-gpu <on|off>             Liga/desliga uso de GPU no NLLB.
    --nllb-legacy / --no-nllb-legacy
                                                                    Forca modo legacy do NLLB on/off.
    --deepl-endpoint <free|pro|URL>
                                                                    Define endpoint DeepL (free/pro/custom URL).
    --reset-deepl-keys-state      Remove estado local de bloqueio de chaves DeepL.
        --whisper-cuda <on|off>      Liga/desliga CUDA no Whisper (transcricao).
        --piper-cuda <on|off>        Liga/desliga CUDA no Piper.
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
            --nllb-profile)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "Parametro --nllb-profile exige um valor."
                    print_usage
                    return 1
                fi
                CLI_NLLB_PROFILE="$1"
                ;;
            --nllb-profile=*)
                CLI_NLLB_PROFILE="${1#*=}"
                ;;
            --nllb-max-input-length)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "Parametro --nllb-max-input-length exige um valor."
                    print_usage
                    return 1
                fi
                CLI_NLLB_MAX_INPUT_LENGTH="$1"
                ;;
            --nllb-max-input-length=*)
                CLI_NLLB_MAX_INPUT_LENGTH="${1#*=}"
                ;;
            --nllb-max-new-tokens)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "Parametro --nllb-max-new-tokens exige um valor."
                    print_usage
                    return 1
                fi
                CLI_NLLB_MAX_NEW_TOKENS="$1"
                ;;
            --nllb-max-new-tokens=*)
                CLI_NLLB_MAX_NEW_TOKENS="${1#*=}"
                ;;
            --nllb-gpu)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "Parametro --nllb-gpu exige um valor (on/off)."
                    print_usage
                    return 1
                fi
                CLI_NLLB_USE_GPU="$1"
                ;;
            --nllb-gpu=*)
                CLI_NLLB_USE_GPU="${1#*=}"
                ;;
            --nllb-legacy)
                CLI_NLLB_LEGACY_GENERATION="1"
                ;;
            --no-nllb-legacy)
                CLI_NLLB_LEGACY_GENERATION="0"
                ;;
            --deepl-endpoint)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "Parametro --deepl-endpoint exige um valor."
                    print_usage
                    return 1
                fi
                CLI_DEEPL_ENDPOINT="$1"
                ;;
            --deepl-endpoint=*)
                CLI_DEEPL_ENDPOINT="${1#*=}"
                ;;
            --reset-deepl-keys-state)
                CLI_RESET_DEEPL_KEYS_STATE="1"
                ;;
            --whisper-cuda)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "Parametro --whisper-cuda exige um valor (on/off)."
                    print_usage
                    return 1
                fi
                CLI_WHISPER_CUDA="$1"
                ;;
            --whisper-cuda=*)
                CLI_WHISPER_CUDA="${1#*=}"
                ;;
            --piper-cuda)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "Parametro --piper-cuda exige um valor (on/off)."
                    print_usage
                    return 1
                fi
                CLI_PIPER_CUDA="$1"
                ;;
            --piper-cuda=*)
                CLI_PIPER_CUDA="${1#*=}"
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

select_piper_execution_mode() {
    local choice

    if [ -n "$CLI_PIPER_CUDA" ]; then
        case "$CLI_PIPER_CUDA" in
            on|ON|On|1|true|TRUE)
                PIPER_USE_CUDA="1"
                ;;
            off|OFF|Off|0|false|FALSE)
                PIPER_USE_CUDA="0"
                ;;
            *)
                log_error "--piper-cuda invalido: $CLI_PIPER_CUDA (use on/off)"
                return 1
                ;;
        esac
        log_step "Piper CUDA definido por CLI: $PIPER_USE_CUDA"
    else
        echo ""
        echo "Execucao do Piper:"
        echo "  1) CPU (padrao)"
        echo "  2) CUDA (GPU)"
        echo ""
        read -r -p "Usar Piper com CUDA? [1/2] (padrao: 1): " choice
        choice="${choice:-1}"
        case "$choice" in
            1|cpu|CPU)
                PIPER_USE_CUDA="0"
                ;;
            2|cuda|CUDA|gpu|GPU)
                PIPER_USE_CUDA="1"
                ;;
            *)
                log_error "Selecao de execucao do Piper invalida: $choice"
                return 1
                ;;
        esac
    fi

    if [ "$PIPER_USE_CUDA" = "1" ]; then
        log_step "Piper CUDA: habilitado"
    else
        log_step "Piper CUDA: desabilitado (CPU)"
    fi

    return 0
}

select_whisper_execution_mode() {
    local choice

    if [ -n "$CLI_WHISPER_CUDA" ]; then
        case "$CLI_WHISPER_CUDA" in
            on|ON|On|1|true|TRUE)
                WHISPER_USE_CUDA="1"
                ;;
            off|OFF|Off|0|false|FALSE)
                WHISPER_USE_CUDA="0"
                ;;
            *)
                log_error "--whisper-cuda invalido: $CLI_WHISPER_CUDA (use on/off)"
                return 1
                ;;
        esac
        log_step "Whisper CUDA definido por CLI: $WHISPER_USE_CUDA"
    else
        echo ""
        echo "Execucao do Whisper (transcricao):"
        echo "  1) CPU (padrao)"
        echo "  2) CUDA (GPU)"
        echo ""
        read -r -p "Usar Whisper com CUDA? [1/2] (padrao: 1): " choice
        choice="${choice:-1}"
        case "$choice" in
            1|cpu|CPU)
                WHISPER_USE_CUDA="0"
                ;;
            2|cuda|CUDA|gpu|GPU)
                WHISPER_USE_CUDA="1"
                ;;
            *)
                log_error "Selecao de execucao do Whisper invalida: $choice"
                return 1
                ;;
        esac
    fi

    if [ "$WHISPER_USE_CUDA" = "1" ]; then
        log_step "Whisper CUDA: habilitado"
    else
        log_step "Whisper CUDA: desabilitado (CPU)"
    fi

    return 0
}

resolve_deepl_base() {
    local endpoint="$1"
    case "$endpoint" in
        free|FREE|Free)
            printf 'https://api-free.deepl.com/v2'
            ;;
        pro|PRO|Pro)
            printf 'https://api.deepl.com/v2'
            ;;
        http://*|https://*)
            printf '%s' "$endpoint"
            ;;
        *)
            printf ''
            ;;
    esac
}

reset_deepl_keys_state_if_requested() {
    if [ "$CLI_RESET_DEEPL_KEYS_STATE" != "1" ]; then
        return 0
    fi

    if [ "$TRANSLATION_BACKEND" != "deepl_doc" ]; then
        log_step "Reset de estado DeepL ignorado (backend atual: $TRANSLATION_BACKEND)"
        return 0
    fi

    rm -f "$DEEPL_KEYS_STATE_INI"
    log_step "Estado de chaves DeepL resetado: ${DEEPL_KEYS_STATE_INI#$ROOT_DIR/}"
    return 0
}

select_translation_backend() {
    local choice
    local default_choice
    local nllb_profile_choice
    local gpu_choice
    local custom_input
    local custom_new
    local nllb_cli_configured=0

    if [ -n "$CLI_TRANSLATION_BACKEND" ]; then
        case "$CLI_TRANSLATION_BACKEND" in
            google)
                TRANSLATION_BACKEND="google"
                ;;
            nllb_local)
                TRANSLATION_BACKEND="nllb_local"
                ;;
            deepl_doc)
                TRANSLATION_BACKEND="deepl_doc"
                ;;
            gemini)
                TRANSLATION_BACKEND="gemini"
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
        deepl_doc)
            default_choice="3"
            ;;
        gemini)
            default_choice="4"
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
        echo "  3) deepl_doc (DeepL document API)"
        echo "  4) gemini (Google Gemini API)"
        echo ""

        read -r -p "Selecione backend de traducao [1/2/3/4] (padrao: ${default_choice}): " choice
        choice="${choice:-$default_choice}"

        case "$choice" in
            1|google|GOOGLE|Google)
                TRANSLATION_BACKEND="google"
                ;;
            2|nllb_local|NLLB_LOCAL|nllb|NLLB)
                TRANSLATION_BACKEND="nllb_local"
                ;;
            3|deepl_doc|DEEPL_DOC|deepl|DEEPL)
                TRANSLATION_BACKEND="deepl_doc"
                ;;
            4|gemini|GEMINI)
                TRANSLATION_BACKEND="gemini"
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

    if [ "$TRANSLATION_BACKEND" = "deepl_doc" ]; then
        local deepl_choice
        local deepl_base_resolved

        if [ ! -f "$ROOT_DIR/workflows/translate_srt.sh" ]; then
            log_error "Workflow DeepL nao encontrado: $ROOT_DIR/workflows/translate_srt.sh"
            return 1
        fi
        if [ -f "$DEEPL_CONFIG_FILE" ]; then
            # shellcheck disable=SC1090
            source "$DEEPL_CONFIG_FILE"
        fi
        if [ ! -f "$DEEPL_KEYS_INI" ]; then
            log_error "Arquivo de chaves DeepL nao encontrado: $DEEPL_KEYS_INI"
            log_step "Copie o template config/translation/deepl_keys_template.ini para config/translation/deepl_keys.ini e preencha as chaves."
            return 1
        fi

        if [ -n "$CLI_DEEPL_ENDPOINT" ]; then
            DEEPL_ENDPOINT="$CLI_DEEPL_ENDPOINT"
        elif [ -z "$CLI_TRANSLATION_BACKEND" ]; then
            echo ""
            echo "Endpoint DeepL:"
            echo "  1) free (api-free.deepl.com)"
            echo "  2) pro  (api.deepl.com)"
            read -r -p "Selecione endpoint DeepL [1/2] (padrao: 1): " deepl_choice
            deepl_choice="${deepl_choice:-1}"
            case "$deepl_choice" in
                1)
                    DEEPL_ENDPOINT="free"
                    ;;
                2)
                    DEEPL_ENDPOINT="pro"
                    ;;
                *)
                    log_error "Selecao de endpoint DeepL invalida: $deepl_choice"
                    return 1
                    ;;
            esac
        fi

        if [ -z "$DEEPL_BASE" ]; then
            deepl_base_resolved="$(resolve_deepl_base "$DEEPL_ENDPOINT")"
            if [ -z "$deepl_base_resolved" ]; then
                log_error "DEEPL endpoint invalido: $DEEPL_ENDPOINT"
                return 1
            fi
            DEEPL_BASE="$deepl_base_resolved"
        fi
    fi

    if [ "$TRANSLATION_BACKEND" = "gemini" ]; then
        if [ -f "$GEMINI_CONFIG_FILE" ]; then
            # shellcheck disable=SC1090
            source "$GEMINI_CONFIG_FILE"
        fi
        if [ -z "${GEMINI_API_KEY:-}" ]; then
            log_error "GEMINI_API_KEY nao definida. Configure em $GEMINI_CONFIG_FILE"
            return 1
        fi
    fi

    if [ -n "$CLI_NLLB_PROFILE" ] || [ -n "$CLI_NLLB_MAX_INPUT_LENGTH" ] || [ -n "$CLI_NLLB_MAX_NEW_TOKENS" ] || [ -n "$CLI_NLLB_USE_GPU" ] || [ -n "$CLI_NLLB_LEGACY_GENERATION" ]; then
        nllb_cli_configured=1
    fi

    if [ "$TRANSLATION_BACKEND" = "nllb_local" ] && [ "$nllb_cli_configured" = "1" ]; then
        if [ -n "$CLI_NLLB_PROFILE" ]; then
            case "$CLI_NLLB_PROFILE" in
                fast)
                    NLLB_LEGACY_GENERATION="0"
                    NLLB_USE_GPU="1"
                    NLLB_MAX_INPUT_LENGTH="768"
                    NLLB_MAX_NEW_TOKENS="192"
                    ;;
                legacy)
                    NLLB_LEGACY_GENERATION="1"
                    ;;
                custom)
                    ;;
                *)
                    log_error "Perfil NLLB invalido via CLI: $CLI_NLLB_PROFILE"
                    return 1
                    ;;
            esac
        fi

        if [ -n "$CLI_NLLB_MAX_INPUT_LENGTH" ]; then
            if ! [[ "$CLI_NLLB_MAX_INPUT_LENGTH" =~ ^[0-9]+$ ]] || [ "$CLI_NLLB_MAX_INPUT_LENGTH" -lt 256 ]; then
                log_error "--nllb-max-input-length invalido: $CLI_NLLB_MAX_INPUT_LENGTH"
                return 1
            fi
            NLLB_MAX_INPUT_LENGTH="$CLI_NLLB_MAX_INPUT_LENGTH"
        fi

        if [ -n "$CLI_NLLB_MAX_NEW_TOKENS" ]; then
            if ! [[ "$CLI_NLLB_MAX_NEW_TOKENS" =~ ^[0-9]+$ ]] || [ "$CLI_NLLB_MAX_NEW_TOKENS" -lt 64 ]; then
                log_error "--nllb-max-new-tokens invalido: $CLI_NLLB_MAX_NEW_TOKENS"
                return 1
            fi
            NLLB_MAX_NEW_TOKENS="$CLI_NLLB_MAX_NEW_TOKENS"
        fi

        if [ -n "$CLI_NLLB_USE_GPU" ]; then
            case "$CLI_NLLB_USE_GPU" in
                on|ON|On|1|true|TRUE)
                    NLLB_USE_GPU="1"
                    ;;
                off|OFF|Off|0|false|FALSE)
                    NLLB_USE_GPU="0"
                    ;;
                *)
                    log_error "--nllb-gpu invalido: $CLI_NLLB_USE_GPU (use on/off)"
                    return 1
                    ;;
            esac
        fi

        if [ -n "$CLI_NLLB_LEGACY_GENERATION" ]; then
            NLLB_LEGACY_GENERATION="$CLI_NLLB_LEGACY_GENERATION"
        fi
    fi

    if [ "$TRANSLATION_BACKEND" = "nllb_local" ] && [ "$nllb_cli_configured" = "0" ] && [ -z "$CLI_TRANSLATION_BACKEND" ]; then
        echo ""
        echo "Perfil de execucao NLLB:"
        echo "  1) Rapido (recomendado)"
        echo "     - legacy=0, gpu=1, max_input=768, max_new=192"
        echo "  2) Compatibilidade (codigo antigo)"
        echo "     - legacy=1"
        echo "  3) Personalizado"
        echo ""
        read -r -p "Selecione perfil NLLB [1/2/3] (padrao: 1): " nllb_profile_choice
        nllb_profile_choice="${nllb_profile_choice:-1}"

        case "$nllb_profile_choice" in
            1)
                NLLB_LEGACY_GENERATION="0"
                NLLB_USE_GPU="1"
                NLLB_MAX_INPUT_LENGTH="768"
                NLLB_MAX_NEW_TOKENS="192"
                ;;
            2)
                NLLB_LEGACY_GENERATION="1"
                ;;
            3)
                read -r -p "Usar GPU? [S/n] (padrao: S): " gpu_choice
                gpu_choice="${gpu_choice:-S}"
                case "$gpu_choice" in
                    s|S|y|Y)
                        NLLB_USE_GPU="1"
                        ;;
                    n|N)
                        NLLB_USE_GPU="0"
                        ;;
                    *)
                        log_error "Selecao de GPU invalida: $gpu_choice"
                        return 1
                        ;;
                esac

                read -r -p "max_input_length (padrao atual: ${NLLB_MAX_INPUT_LENGTH}): " custom_input
                custom_input="${custom_input:-$NLLB_MAX_INPUT_LENGTH}"
                if ! [[ "$custom_input" =~ ^[0-9]+$ ]] || [ "$custom_input" -lt 256 ]; then
                    log_error "max_input_length invalido: $custom_input"
                    return 1
                fi
                NLLB_MAX_INPUT_LENGTH="$custom_input"

                read -r -p "max_new_tokens (padrao atual: ${NLLB_MAX_NEW_TOKENS}): " custom_new
                custom_new="${custom_new:-$NLLB_MAX_NEW_TOKENS}"
                if ! [[ "$custom_new" =~ ^[0-9]+$ ]] || [ "$custom_new" -lt 64 ]; then
                    log_error "max_new_tokens invalido: $custom_new"
                    return 1
                fi
                NLLB_MAX_NEW_TOKENS="$custom_new"

                read -r -p "Usar modo legacy? [s/N] (padrao: N): " choice
                choice="${choice:-N}"
                case "$choice" in
                    s|S|y|Y)
                        NLLB_LEGACY_GENERATION="1"
                        ;;
                    n|N)
                        NLLB_LEGACY_GENERATION="0"
                        ;;
                    *)
                        log_error "Selecao legacy invalida: $choice"
                        return 1
                        ;;
                esac
                ;;
            *)
                log_error "Perfil NLLB invalido: $nllb_profile_choice"
                return 1
                ;;
        esac
    fi

    log_step "Backend de traducao selecionado: $TRANSLATION_BACKEND"
    if [ "$TRANSLATION_BACKEND" = "nllb_local" ]; then
        log_step "Diretorio do modelo NLLB: ${NLLB_MODEL_DIR#$ROOT_DIR/}"
        log_step "NLLB max_input_length: $NLLB_MAX_INPUT_LENGTH"
        log_step "NLLB max_new_tokens: $NLLB_MAX_NEW_TOKENS"
        log_step "NLLB use_gpu: $NLLB_USE_GPU"
        log_step "NLLB legacy_generation: $NLLB_LEGACY_GENERATION"
    elif [ "$TRANSLATION_BACKEND" = "deepl_doc" ]; then
        log_step "DEEPL keys INI: ${DEEPL_KEYS_INI#$ROOT_DIR/}"
        log_step "DEEPL keys state INI: ${DEEPL_KEYS_STATE_INI#$ROOT_DIR/}"
        log_step "DEEPL env legado: ${DEEPL_CONFIG_FILE#$ROOT_DIR/}"
        log_step "DEEPL endpoint: $DEEPL_ENDPOINT"
        log_step "DEEPL base: $DEEPL_BASE"
    elif [ "$TRANSLATION_BACKEND" = "gemini" ]; then
        log_step "GEMINI config: ${GEMINI_CONFIG_FILE#$ROOT_DIR/}"
        log_step "GEMINI model: $GEMINI_MODEL"
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

    if [[ "$source_dir" = "$DATA_DIR" ]]; then
        rel_dir="root"
    elif [[ "$source_dir" = "$DATA_DIR/"* ]]; then
        rel_dir="${source_dir#$DATA_DIR/}"
    else
        rel_dir="external/$(printf '%s' "$source_dir" | sed -e 's#^/##' -e 's#[^A-Za-z0-9._/-]#_#g')"
    fi

    target_dir="$ARCHIVE_ROOT/$rel_dir"
    mkdir -p "$target_dir"

    for artifact in \
        "$source_dir/$source_base.srt" \
        "$source_dir/$source_base.srtpt" \
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

video_log_file_from_path() {
    local video_file="$1"
    local base_name
    base_name="$(basename "${video_file%.*}")"
    printf '%s/exec-%s-%s.log' "$LOG_DIR" "$TIMESTAMP" "$base_name"
}

process_video_pre_translation() {
    local video_file="$1"
    local selected_dir
    local base_name
    local audio_wav
    local output_srt
    local output_srtpt
    local output_pt_wav
    local whisper_lang
    local source_lang
    local state_file
    local video_log_file
    local deepl_source_lang
    local translation_cmd
    local whisper_device

    selected_dir="$(dirname "$video_file")"
    base_name="$(basename "${video_file%.*}")"
    video_log_file="$(video_log_file_from_path "$video_file")"
    LOG_FILE="$video_log_file"
    audio_wav="$selected_dir/$base_name.wav"
    output_srt="$selected_dir/$base_name.srt"
    output_srtpt="$selected_dir/$base_name.srtpt"
    output_pt_wav="$selected_dir/$base_name.pt.wav"
    state_file="$(state_file_for_video "$video_file")"

    whisper_lang="auto"
    source_lang="auto"
    whisper_device="cpu"
    if [ "$WHISPER_USE_CUDA" = "1" ]; then
        whisper_device="cuda"
    fi

    state_set "$state_file" "input_video" "$video_file"
    state_set "$state_file" "scope" "$DATA_SCOPE_REL"
    state_set "$state_file" "audio_wav" "$audio_wav"
    state_set "$state_file" "output_srt" "$output_srt"
    state_set "$state_file" "output_srtpt" "$output_srtpt"
    state_set "$state_file" "output_pt_wav" "$output_pt_wav"
    state_set "$state_file" "last_run" "$(date -Iseconds)"

    log_section "Fase 1 - Preparacao (Whisper + Traducao): ${video_file#$ROOT_DIR/}"
    log_step "Idioma transcricao: $whisper_lang (deteccao automatica)"
    log_step "Whisper device: $whisper_device"
    log_step "State file: ${state_file#$ROOT_DIR/}"
    if [ "$RUN_LOG_FILE" != "$video_log_file" ]; then
        log_step "Log do video: ${video_log_file#$ROOT_DIR/}"
    fi

    if [ "$ARCHIVE_ON_START" = "1" ]; then
        log_section "Limpeza por Arquivamento"
        archive_previous_outputs "$video_file"
    else
        log_step "Arquivamento automatico desabilitado (ARCHIVE_ON_START=0)"
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
    if [ "$WHISPER_USE_CUDA" = "1" ]; then
        log_step "Whisper CUDA: ON"
    else
        log_step "Whisper CUDA: OFF"
    fi
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
            "$base_name" \
            --device "$whisper_device"

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
    if [ "$RESUME_MODE" = "1" ] && validate_translation_ready "$output_srt" "$output_srtpt"; then
        update_step_state "$state_file" "translate" "success" "reutilizado"
        log_step "Traducao valida ja existente: ${output_srtpt#$ROOT_DIR/}"
    else
        update_step_state "$state_file" "translate" "running" "traduzindo"
        if [ "$TRANSLATION_BACKEND" = "deepl_doc" ]; then
            case "$source_lang" in
                zh-CN)
                    deepl_source_lang="ZH"
                    ;;
                es)
                    deepl_source_lang="ES"
                    ;;
                *)
                    deepl_source_lang="AUTO"
                    ;;
            esac
            DEEPL_BASE="$DEEPL_BASE" "$ROOT_DIR/workflows/translate_srt.sh" \
                --keys-ini "$DEEPL_KEYS_INI" \
                --keys-state-ini "$DEEPL_KEYS_STATE_INI" \
                --source-lang "$deepl_source_lang" \
                --target-lang "PT-BR" \
                "$output_srt" \
                "$output_srtpt"
        else
            translation_cmd=(
                "$PYTHON_BIN" "$ROOT_DIR/scripts/traduzir.py"
                "$output_srt"
                "$output_srtpt"
                "$source_lang"
                --backend "$TRANSLATION_BACKEND"
                --gemini-model "$GEMINI_MODEL"
                --nllb-model-dir "$NLLB_MODEL_DIR"
            )

            if [ "$TRANSLATION_BACKEND" = "nllb_local" ]; then
                translation_cmd+=(
                    --nllb-max-input-length "$NLLB_MAX_INPUT_LENGTH"
                    --nllb-max-new-tokens "$NLLB_MAX_NEW_TOKENS"
                )
                if [ "$NLLB_USE_GPU" = "1" ]; then
                    translation_cmd+=(--nllb-use-gpu)
                fi
                if [ "$NLLB_LEGACY_GENERATION" = "1" ]; then
                    translation_cmd+=(--nllb-legacy-generation)
                fi
            fi

            if [ "$TRANSLATION_BACKEND" = "gemini" ]; then
                GEMINI_API_KEY="${GEMINI_API_KEY:-}" GEMINI_MODEL="$GEMINI_MODEL" "${translation_cmd[@]}"
            else
                "${translation_cmd[@]}"
            fi
        fi

        if ! validate_translation_ready "$output_srt" "$output_srtpt"; then
            update_step_state "$state_file" "translate" "failed" "SRT traduzido nao validado"
            log_error "SRT traduzido nao gerado/validado: $output_srtpt"
            return 1
        fi
        update_step_state "$state_file" "translate" "success" "SRT traduzido validado"
        log_step "Traducao gerada: ${output_srtpt#$ROOT_DIR/}"
    fi

    return 0
}

process_video_audiobook_phase() {
    local video_file="$1"
    local selected_dir
    local base_name
    local output_srt
    local output_srtpt
    local output_pt_wav
    local source_lang
    local state_file
    local video_log_file
    local generate_audio_cmd

    selected_dir="$(dirname "$video_file")"
    base_name="$(basename "${video_file%.*}")"
    output_srt="$selected_dir/$base_name.srt"
    output_srtpt="$selected_dir/$base_name.srtpt"
    output_pt_wav="$selected_dir/$base_name.pt.wav"
    state_file="$(state_file_for_video "$video_file")"
    video_log_file="$(video_log_file_from_path "$video_file")"
    LOG_FILE="$video_log_file"

    source_lang="$(infer_translation_lang_from_srt "$output_srt")"
    if [ "$source_lang" = "auto" ]; then
        source_lang="$(infer_translation_lang_from_name "$base_name")"
    fi

    state_set "$state_file" "input_video" "$video_file"
    state_set "$state_file" "scope" "$DATA_SCOPE_REL"
    state_set "$state_file" "output_srt" "$output_srt"
    state_set "$state_file" "output_srtpt" "$output_srtpt"
    state_set "$state_file" "output_pt_wav" "$output_pt_wav"
    state_set "$state_file" "source_lang" "$source_lang"
    state_set "$state_file" "last_run" "$(date -Iseconds)"

    log_section "Fase 3 - Geracao de Audiobook: ${video_file#$ROOT_DIR/}"
    log_step "State file: ${state_file#$ROOT_DIR/}"
    if [ "$RUN_LOG_FILE" != "$video_log_file" ]; then
        log_step "Log do video: ${video_log_file#$ROOT_DIR/}"
    fi

    log_section "Etapa 3 - Geracao de Audiobook"
    if [ "$PIPER_USE_CUDA" = "1" ]; then
        log_step "Piper CUDA: ON"
    else
        log_step "Piper CUDA: OFF"
    fi
    if [ "$RESUME_MODE" = "1" ] && validate_audio_ready "$output_srtpt" "$output_pt_wav"; then
        update_step_state "$state_file" "audiobook" "success" "reutilizado"
        log_step "Audiobook valido ja existente: ${output_pt_wav#$ROOT_DIR/}"
    else
        update_step_state "$state_file" "audiobook" "running" "gerando audio"
        generate_audio_cmd=(
            "$PYTHON_BIN" -u "$ROOT_DIR/scripts/gerar-sincronizado.py"
            --srt "$output_srtpt"
            --output "$output_pt_wav"
            --model "$MODELS_DIR/$VOICE_MODEL"
            --piper "$PIPER_BIN"
            --source_lang "$source_lang"
            --pause_duration 0.1
        )

        if [ "$PIPER_USE_CUDA" = "1" ]; then
            generate_audio_cmd+=(--piper-cuda)
        fi

        "${generate_audio_cmd[@]}"

        if ! validate_audio_ready "$output_srtpt" "$output_pt_wav"; then
            update_step_state "$state_file" "audiobook" "failed" "audio final nao validado"
            log_error "Audio final nao gerado/validado: $output_pt_wav"
            return 1
        fi
        update_step_state "$state_file" "audiobook" "success" "audio validado"
        log_step "Audiobook gerado: ${output_pt_wav#$ROOT_DIR/}"
    fi

    return 0
}

move_processed_bundle_to_done() {
    local video_file="$1"
    local selected_dir
    local base_name
    local source_file
    local target_file
    local moved=0

    selected_dir="$(dirname "$video_file")"
    base_name="$(basename "${video_file%.*}")"

    log_section "Fase 4 - Movimentacao para done"

    for source_file in \
        "$selected_dir/$base_name.mkv" \
        "$selected_dir/$base_name.mp4" \
        "$selected_dir/$base_name.wav" \
        "$selected_dir/$base_name.srt" \
        "$selected_dir/$base_name.srtpt" \
        "$selected_dir/$base_name.pt.wav"
    do
        if [ -f "$source_file" ]; then
            target_file="$DONE_DIR/$(basename "$source_file")"
            mv -f "$source_file" "$target_file"
            moved=$((moved + 1))
            log_step "Movido para done: ${target_file#$ROOT_DIR/}"
        fi
    done

    if [ "$moved" -eq 0 ]; then
        log_error "Nenhum arquivo encontrado para mover para done: $base_name"
        return 1
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
    log_step "Diretorio de trabalho (exec): ${WORK_EXEC_DIR#$ROOT_DIR/}"
    log_step "Diretorio de concluidos (done): ${DONE_DIR#$ROOT_DIR/}"
    log_step "Diretorio de publicados (published): ${PUBLISHED_DIR#$ROOT_DIR/}"
    log_step "Diretorio de remux: ${REMUX_DIR#$ROOT_DIR/}"
    log_step "Resume mode: $RESUME_MODE"
    log_step "Archive on start: $ARCHIVE_ON_START"

    log_section "Selecao de Backend de Traducao"
    if ! select_translation_backend; then
        log_summary "FALHA" "Selecao de backend invalida"
        exit 1
    fi
    if ! reset_deepl_keys_state_if_requested; then
        log_summary "FALHA" "Reset do estado de chaves DeepL"
        exit 1
    fi

    log_section "Modo de Execucao do Whisper"
    if ! select_whisper_execution_mode; then
        log_summary "FALHA" "Selecao do Whisper invalida"
        exit 1
    fi

    log_section "Modo de Execucao do Piper"
    if ! select_piper_execution_mode; then
        log_summary "FALHA" "Selecao do Piper invalida"
        exit 1
    fi

    log_section "Indexando lista de arquivos"
    mapfile -t VIDEO_FILES < <(list_video_files)

    if [ "${#VIDEO_FILES[@]}" -eq 0 ]; then
        log_error "Nenhum arquivo .mkv/.mp4 encontrado em ${WORK_EXEC_DIR#$ROOT_DIR/}"
        log_summary "FALHA" "Sem videos"
        exit 1
    fi

    VIDEO_LANGS=()
    for video in "${VIDEO_FILES[@]}"; do
        inferred_source_lang="$(infer_original_lang_for_video "$video")"
        VIDEO_LANGS+=("$inferred_source_lang")
        log_step "Video detectado: ${video#$ROOT_DIR/}"
    done

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
    total_selected="${#SELECTED_VIDEOS[@]}"
    phase1_success=0
    phase1_fail=0
    phase2_success=0
    phase2_fail=0
    phase3_success=0
    phase3_fail=0

    log_section "Fase 1 (lote) - Whisper + Traducao"
    READY_FOR_AUDIO_VIDEOS=()
    for selected_video in "${SELECTED_VIDEOS[@]}"; do
        selected_video_log="$(video_log_file_from_path "$selected_video")"
        LOG_FILE="$selected_video_log"
        if process_video_pre_translation "$selected_video" > >(tee -a "$selected_video_log") 2>&1; then
            phase1_success=$((phase1_success + 1))
            READY_FOR_AUDIO_VIDEOS+=("$selected_video")
        else
            phase1_fail=$((phase1_fail + 1))
            fail_count=$((fail_count + 1))
        fi
    done

    log_section "Fase 2 (lote) - Geracao WAV (Piper)"
    for phase_video in "${READY_FOR_AUDIO_VIDEOS[@]}"; do
        phase_video_log="$(video_log_file_from_path "$phase_video")"
        LOG_FILE="$phase_video_log"
        if process_video_audiobook_phase "$phase_video" > >(tee -a "$phase_video_log") 2>&1; then
            phase2_success=$((phase2_success + 1))
            if move_processed_bundle_to_done "$phase_video" > >(tee -a "$phase_video_log") 2>&1; then
                phase3_success=$((phase3_success + 1))
                success_count=$((success_count + 1))
            else
                phase3_fail=$((phase3_fail + 1))
                fail_count=$((fail_count + 1))
            fi
        else
            phase2_fail=$((phase2_fail + 1))
            fail_count=$((fail_count + 1))
        fi
    done

    success_count="$phase3_success"
    fail_count=$((phase1_fail + phase2_fail + phase3_fail))

    log_section "Resumo por Fase"
    log_step "Total selecionado: $total_selected"
    log_step "Fase 1 (Whisper + Traducao) - sucesso: $phase1_success | falha: $phase1_fail"
    log_step "Fase 2 (Piper) - sucesso: $phase2_success | falha: $phase2_fail"
    log_step "Fase 3 (Mover para done) - sucesso: $phase3_success | falha: $phase3_fail"

    log_section "Resumo Final"
    log_step "Videos com sucesso: $success_count"
    log_step "Videos com falha: $fail_count"

    if [ "$fail_count" -gt 0 ]; then
        log_summary "FALHA" "Uma ou mais execucoes falharam"
        exit 1
    fi

    log_summary "SUCCESS" ""
} 2>&1 | tee -a "$RUN_LOG_FILE"
