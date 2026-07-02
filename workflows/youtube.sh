#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG_FILE="${PIPELINE_CONFIG:-$ROOT_DIR/config/pipeline.ini}"
DATA_DIR="$ROOT_DIR/data"
DATA_SCOPE_REL="data"
TMP_WORK_DIR=""

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SCRIPT_NAME="YouTube Downloader"
SCRIPT_START_TIME="$(date +%s)"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/youtube-${TIMESTAMP}.log"

source "$ROOT_DIR/scripts/log_helpers.sh"

OUTPUT_DIR=""
VIDEO_URL=""
VIDEO_TITLE=""
VIDEO_ID=""
DOWNLOAD_FILE=""
COOKIES_FROM_BROWSER="${YOUTUBE_COOKIES_FROM_BROWSER:-}"
COOKIES_FILE="${YOUTUBE_COOKIES_FILE:-}"

print_usage() {
    cat <<'EOF'
Uso: workflows/youtube.sh [opcoes] <link_youtube>

Opcoes:
    --cookies-from-browser <nome> Usa cookies do navegador (ex.: firefox, chrome, chromium, edge).
    --cookies-file <arquivo>      Usa arquivo cookies.txt exportado do navegador.
    --help                       Exibe esta ajuda.

Exemplos:
    bash workflows/youtube.sh "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    bash workflows/youtube.sh --cookies-from-browser firefox "https://youtu.be/dQw4w9WgXcQ"
EOF
}

parse_cli_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --cookies-from-browser)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "Parametro --cookies-from-browser exige um valor."
                    print_usage
                    return 1
                fi
                COOKIES_FROM_BROWSER="$1"
                ;;
            --cookies-from-browser=*)
                COOKIES_FROM_BROWSER="${1#*=}"
                ;;
            --cookies-file)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "Parametro --cookies-file exige um valor."
                    print_usage
                    return 1
                fi
                COOKIES_FILE="$1"
                ;;
            --cookies-file=*)
                COOKIES_FILE="${1#*=}"
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                if [ -z "$VIDEO_URL" ]; then
                    VIDEO_URL="$1"
                else
                    log_error "Parametro inesperado: $1"
                    print_usage
                    return 1
                fi
                ;;
        esac
        shift
    done

    if [ -z "$VIDEO_URL" ]; then
        log_error "Link do YouTube nao informado."
        print_usage
        return 1
    fi

    return 0
}

validate_cookie_inputs() {
    if [ -n "$COOKIES_FILE" ]; then
        COOKIES_FILE="$(realpath -m "$COOKIES_FILE")"
        if [ ! -f "$COOKIES_FILE" ]; then
            log_error "Arquivo de cookies nao encontrado: $COOKIES_FILE"
            log_step "Use --cookies-file com um cookies.txt valido exportado do navegador"
            return 1
        fi
        if [ ! -r "$COOKIES_FILE" ]; then
            log_error "Sem permissao de leitura no arquivo de cookies: $COOKIES_FILE"
            return 1
        fi
    fi
    return 0
}

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

validate_youtube_url() {
    local url="$1"
    if [[ "$url" =~ ^https?://(www\.)?(youtube\.com|youtu\.be)/.+$ ]]; then
        return 0
    fi

    log_error "URL invalida: $url"
    log_step "Aceito apenas links http/https de youtube.com ou youtu.be"
    return 1
}

ensure_command() {
    local cmd="$1"
    local install_hint="$2"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Dependencia ausente: $cmd"
        log_step "Como corrigir: $install_hint"
        return 1
    fi

    return 0
}

prepare_output_dir() {
    OUTPUT_DIR="$DATA_DIR/downloaded"
    TMP_WORK_DIR="$OUTPUT_DIR/workdir"
    LOG_DIR="$DATA_DIR/logs"
    LOG_FILE="$LOG_DIR/youtube-${TIMESTAMP}.log"

    mkdir -p "$OUTPUT_DIR" "$TMP_WORK_DIR" "$LOG_DIR"

    OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"
    TMP_WORK_DIR="$(realpath -m "$TMP_WORK_DIR")"

    if [ ! -d "$OUTPUT_DIR" ]; then
        log_error "Diretorio de saida nao existe: $OUTPUT_DIR"
        return 1
    fi

    if [ ! -w "$OUTPUT_DIR" ]; then
        log_error "Sem permissao de escrita no diretorio de saida: $OUTPUT_DIR"
        log_step "Verifique permissoes do diretorio ou execute em uma pasta com escrita liberada"
        return 1
    fi

    if [ ! -w "$TMP_WORK_DIR" ]; then
        log_error "Sem permissao de escrita no workdir temporario: $TMP_WORK_DIR"
        log_step "Esse workdir e usado por yt-dlp/ffmpeg e arquivos temporarios de extracao/conversao"
        return 1
    fi

    export TMPDIR="$TMP_WORK_DIR"
    return 0
}

resolve_video_metadata() {
    local metadata_file
    local metadata_ok=0
    metadata_file="$(mktemp)"

    run_metadata_attempt() {
        set +e
        yt-dlp --skip-download --print "%(title)s" --print "%(id)s" "$@" "$VIDEO_URL" >"$metadata_file" 2>&1
        local meta_exit=$?
        set -e
        if [ "$meta_exit" -eq 0 ]; then
            metadata_ok=1
            return 0
        fi
        return 1
    }

    run_metadata_attempt || true
    if [ "$metadata_ok" -ne 1 ]; then
        run_metadata_attempt --extractor-args "youtube:player_client=android,web" || true
    fi
    if [ "$metadata_ok" -ne 1 ] && [ -n "$COOKIES_FROM_BROWSER" ]; then
        run_metadata_attempt --cookies-from-browser "$COOKIES_FROM_BROWSER" || true
    fi
    if [ "$metadata_ok" -ne 1 ] && [ -n "$COOKIES_FILE" ]; then
        run_metadata_attempt --cookies "$COOKIES_FILE" || true
    fi

    if [ "$metadata_ok" -ne 1 ]; then
        log_error "Falha ao consultar metadados do video."
        log_step "Possiveis causas: link inexistente, bloqueio por rede/proxy, rate-limit, video privado ou restricao regional"
        log_step "Saida detalhada do yt-dlp:"
        sed 's/^/    /' "$metadata_file"
        rm -f "$metadata_file"
        return 1
    fi

    VIDEO_TITLE="$(sed -n '1p' "$metadata_file" | tr -d '\r')"
    VIDEO_ID="$(sed -n '2p' "$metadata_file" | tr -d '\r')"

    rm -f "$metadata_file"

    if [ -z "$VIDEO_TITLE" ] || [ -z "$VIDEO_ID" ]; then
        log_error "Nao foi possivel extrair titulo/ID do video."
        log_step "Saida inesperada da consulta de metadados; valide o link e atualize o yt-dlp"
        return 1
    fi

    return 0
}

download_video_mp4() {
    local attempt_log
    local output_template
    local ytdlp_exit=1
    local attempt_ok=0
    local last_attempt_log=""
    local attempt_label=""
    local median_format_id=""

    output_template="$OUTPUT_DIR/%(title).200B [%(id)s].%(ext)s"

    local -a common_args=(
        --newline
        --progress
        --restrict-filenames
        --no-warnings
        --paths "home:$OUTPUT_DIR"
        --paths "temp:$TMP_WORK_DIR"
        --format "bv*+ba/b"
        --merge-output-format mp4
        --output "$output_template"
        --print "after_move:DOWNLOAD_FILE=%(filepath)s"
    )

    log_step "Iniciando download com progresso detalhado"
    log_step "Estrategia de fallback habilitada para erros 403/Forbidden"

    run_attempt() {
        attempt_label="$1"
        shift
        attempt_log="$(mktemp)"
        last_attempt_log="$attempt_log"

        log_step "Tentativa: $attempt_label"
        set +e
        yt-dlp "${common_args[@]}" "$@" "$VIDEO_URL" 2>&1 | tee "$attempt_log"
        ytdlp_exit=${PIPESTATUS[0]}
        set -e

        DOWNLOAD_FILE="$(grep -E '^DOWNLOAD_FILE=' "$attempt_log" | tail -n 1 | sed 's/^DOWNLOAD_FILE=//')"
        if [ "$ytdlp_exit" -eq 0 ] && [ -n "$DOWNLOAD_FILE" ] && [ -f "$DOWNLOAD_FILE" ]; then
            attempt_ok=1
            return 0
        fi

        log_step "Tentativa falhou: $attempt_label (exit=$ytdlp_exit)"
        return 1
    }

    pick_median_format_id() {
        local format_log
        local format_json
        local selected_info
        local fmt_exit
        local json_exit
        local -a list_args=()

        format_log="$(mktemp)"
        format_json="$(mktemp)"

        if [ -n "$COOKIES_FROM_BROWSER" ]; then
            list_args+=(--cookies-from-browser "$COOKIES_FROM_BROWSER")
        elif [ -n "$COOKIES_FILE" ]; then
            list_args+=(--cookies "$COOKIES_FILE")
        fi

        set +e
        yt-dlp -F "${list_args[@]}" "$VIDEO_URL" 2>&1 | tee "$format_log"
        fmt_exit=${PIPESTATUS[0]}
        set -e

        if [ "$fmt_exit" -ne 0 ]; then
            log_step "Nao foi possivel listar formatos disponiveis (exit=$fmt_exit)."
            rm -f "$format_log"
            return 1
        fi

        log_section "Formatos Disponiveis (fallback)"
        sed 's/^/    /' "$format_log"

        set +e
        yt-dlp -J "${list_args[@]}" "$VIDEO_URL" >"$format_json" 2>/dev/null
        json_exit=$?
        set -e

        if [ "$json_exit" -eq 0 ]; then
            selected_info="$(python3 - "$format_json" <<'PY'
import json
import sys

target_height = 720

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

formats = data.get("formats") or []

def as_float(value, default=0.0):
    try:
        return float(value)
    except Exception:
        return default

def as_int(value, default=0):
    try:
        return int(value)
    except Exception:
        return default

combined = []
for f in formats:
    fid = str(f.get("format_id") or "").strip()
    if not fid:
        continue

    vcodec = str(f.get("vcodec") or "none")
    acodec = str(f.get("acodec") or "none")
    if vcodec == "none" or acodec == "none":
        continue

    ext = str(f.get("ext") or "")
    height = as_int(f.get("height"), -1)
    tbr = as_float(f.get("tbr"), 0.0)
    filesize = as_int(f.get("filesize") or f.get("filesize_approx"), 0)

    distance = abs(height - target_height) if height > 0 else 9999
    ext_penalty = 0 if ext == "mp4" else 1

    combined.append((
        distance,
        ext_penalty,
        -tbr,
        -filesize,
        fid,
        height,
        ext,
        tbr,
    ))

if combined:
    chosen = sorted(combined)[0]
    fid = chosen[4]
    height = chosen[5]
    ext = chosen[6]
    tbr = chosen[7]
    print(fid)
    print(f"target=~{target_height}p selected={height if height > 0 else 'unknown'}p ext={ext} tbr={tbr:.1f}")
    sys.exit(0)

all_ids = [str(f.get("format_id") or "").strip() for f in formats if str(f.get("format_id") or "").strip()]
if all_ids:
    idx = len(all_ids) // 2
    print(all_ids[idx])
    print("fallback=median_by_position")
    sys.exit(0)

print("")
print("fallback=none")
PY
)"
        else
            selected_info=""
        fi

        median_format_id="$(printf '%s\n' "$selected_info" | sed -n '1p')"

        rm -f "$format_log" "$format_json"

        if [ -n "$median_format_id" ]; then
            log_step "Formato fallback selecionado: $median_format_id"
            local selection_meta
            selection_meta="$(printf '%s\n' "$selected_info" | sed -n '2p')"
            if [ -n "$selection_meta" ]; then
                log_step "Criterio: $selection_meta"
            fi
            return 0
        fi
        log_step "Nenhum format_id elegivel encontrado para fallback automatico."
        return 1
    }

    run_attempt "padrao (sem autenticacao)" || true

    if [ "$attempt_ok" -ne 1 ]; then
        run_attempt "cliente alternativo (android/web)" --extractor-args "youtube:player_client=android,web" || true
    fi

    if [ "$attempt_ok" -ne 1 ] && [ -n "$COOKIES_FROM_BROWSER" ]; then
        run_attempt "cookies do navegador ($COOKIES_FROM_BROWSER)" --cookies-from-browser "$COOKIES_FROM_BROWSER" || true
    fi

    if [ "$attempt_ok" -ne 1 ] && [ -n "$COOKIES_FILE" ]; then
        run_attempt "cookies via arquivo" --cookies "$COOKIES_FILE" || true
    fi

    if [ "$attempt_ok" -ne 1 ] && pick_median_format_id; then
        if [ -n "$COOKIES_FROM_BROWSER" ]; then
            run_attempt "formato mediano com cookies do navegador" --cookies-from-browser "$COOKIES_FROM_BROWSER" -f "$median_format_id" || true
        fi
        if [ "$attempt_ok" -ne 1 ] && [ -n "$COOKIES_FILE" ]; then
            run_attempt "formato mediano com cookies via arquivo" --cookies "$COOKIES_FILE" -f "$median_format_id" || true
        fi
        if [ "$attempt_ok" -ne 1 ]; then
            run_attempt "formato mediano sem autenticacao" -f "$median_format_id" || true
        fi
    fi

    if [ "$attempt_ok" -eq 1 ]; then
        [ -n "$last_attempt_log" ] && rm -f "$last_attempt_log"
        return 0
    fi

    if [ "$ytdlp_exit" -ne 0 ]; then
        log_error "Download falhou (codigo de saida: $ytdlp_exit)."
        log_step "Possiveis causas: URL invalida, conectividade, bloqueio geolocalizado, ffmpeg ausente, espaco em disco insuficiente"
        if [ -n "$last_attempt_log" ] && grep -Eqi 'forbidden|http error 403|sign in to confirm|bot' "$last_attempt_log"; then
            log_step "Diagnostico: o YouTube provavelmente exigiu sessao autenticada para este video (mesmo sendo reproduzivel no navegador)."
            log_step "Tente: --cookies-from-browser firefox (ou chrome/chromium/edge)."
            log_step "Alternativa: exporte cookies.txt e use --cookies-file /caminho/cookies.txt"
        fi
        log_step "Trecho final da saida do yt-dlp:"
        if [ -n "$last_attempt_log" ] && [ -f "$last_attempt_log" ]; then
            tail -n 30 "$last_attempt_log" | sed 's/^/    /'
            rm -f "$last_attempt_log"
        fi
        return 1
    fi

    if [ -z "$DOWNLOAD_FILE" ]; then
        log_error "Download terminou, mas o arquivo final nao foi identificado pelo yt-dlp."
        log_step "Possivel causa: formato de saida inesperado do yt-dlp; atualize o parser ou a versao da ferramenta"
        return 1
    fi

    if [ ! -f "$DOWNLOAD_FILE" ]; then
        log_error "Arquivo final informado nao existe: $DOWNLOAD_FILE"
        log_step "Possivel causa: falha de merge/conversao apos download"
        return 1
    fi

    return 0
}

main() {
    if ! parse_cli_args "$@"; then
        exit 1
    fi

    if ! configure_data_scope; then
        log_summary "FALHA" "Escopo de dados invalido"
        exit 1
    fi

    if ! validate_cookie_inputs; then
        log_summary "FALHA" "Parametros de cookies invalidos"
        exit 1
    fi

    if ! prepare_output_dir; then
        exit 1
    fi

    {
        log_header

        log_section "Pre-requisitos"
        log_step "Config: ${CONFIG_FILE#$ROOT_DIR/}"
        log_step "Escopo de dados: ${DATA_DIR#$ROOT_DIR/}"
        log_step "Diretorio de saida: $OUTPUT_DIR"
        log_step "Workdir temporario: $TMP_WORK_DIR"
        if [ -n "$COOKIES_FROM_BROWSER" ]; then
            log_step "Cookies por navegador: $COOKIES_FROM_BROWSER"
        elif [ -n "$COOKIES_FILE" ]; then
            log_step "Cookies por arquivo: $COOKIES_FILE"
        else
            log_step "Cookies: nao informados (modo anonimo + fallback)"
        fi
        log_step "Log detalhado: $LOG_FILE"

        if ! validate_youtube_url "$VIDEO_URL"; then
            log_summary "FALHA" "URL invalida"
            exit 1
        fi

        if ! ensure_command "yt-dlp" "Instale o yt-dlp (ex.: pip install yt-dlp ou pacote do sistema)."; then
            log_summary "FALHA" "yt-dlp ausente"
            exit 1
        fi

        if ! ensure_command "ffmpeg" "Instale o ffmpeg para merge de audio+video em mp4."; then
            log_summary "FALHA" "ffmpeg ausente"
            exit 1
        fi

        log_section "Resolucao de Metadados"
        if ! resolve_video_metadata; then
            log_summary "FALHA" "Nao foi possivel consultar metadados"
            exit 1
        fi

        log_step "Titulo: $VIDEO_TITLE"
        log_step "ID: $VIDEO_ID"

        log_section "Download MP4"
        if ! download_video_mp4; then
            log_summary "FALHA" "Erro durante download"
            exit 1
        fi

        log_step "Arquivo gerado: $DOWNLOAD_FILE"
        log_step "Variavel de integracao: YOUTUBE_DOWNLOADED_FILE=$DOWNLOAD_FILE"

        log_section "Integracao Futura"
        log_step "Este workflow ja expõe o arquivo final em formato estavel para encadeamento com outros scripts"

        log_summary "SUCCESS" ""
    } 2>&1 | tee -a "$LOG_FILE"
}

main "$@"
