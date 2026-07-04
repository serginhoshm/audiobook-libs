#!/usr/bin/env bash
# translate_srt.sh — Traduz arquivo SRT via DeepL API (document translation).
#
# Uso:
#   ./translate_srt.sh [--source-lang ZH|ES|AUTO] [--target-lang PT-BR] <entrada.srt> [saida.srt]
#
# Chaves (rotacao por bloco):
#   config/translation/deepl_keys.ini
#   [deepl_keys]
#   key_1 = sua-chave-1
#   key_2 = sua-chave-2
#
# Dependencias: curl, python3 (stdlib apenas)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DEEPL_BASE="${DEEPL_BASE:-https://api-free.deepl.com/v2}"
DEEPL_KEYS_INI="${DEEPL_KEYS_INI:-$ROOT_DIR/config/translation/deepl_keys.ini}"
DEEPL_KEYS_STATE_INI="${DEEPL_KEYS_STATE_INI:-$ROOT_DIR/config/translation/deepl_keys_state.ini}"
SOURCE_LANG="${SOURCE_LANG:-ZH}"
TARGET_LANG="${TARGET_LANG:-PT-BR}"
POLL_INTERVAL=5
DEEPL_USAGE_TIMEOUT_SECONDS="${DEEPL_USAGE_TIMEOUT_SECONDS:-12}"
MAX_UPLOAD_BYTES="${DEEPL_DOC_MAX_BYTES:-81920}"
KEY_QUOTA_HTTP_CODE="456"
KEY_QUOTA_RETURN_CODE=56
RESET_KEYS_STATE=0
CURRENT_KEY_INDEX=0
ACTIVE_DEEPL_API_KEY=""
ACTIVE_DEEPL_KEY_SLOT=0
declare -a DEEPL_API_KEYS=()
declare -a BLOCKED_KEY_PREFIXES=()

# --- helpers ---
die() { echo "Erro: $*" >&2; exit 1; }

parse_json() {
    # parse_json <json_string> <campo>
    echo "$1" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('$2', ''))
" 2>/dev/null || echo ""
}

file_size_bytes() {
    local file="$1"
    wc -c < "$file" | tr -d ' '
}

load_deepl_keys_from_ini() {
    local ini_file="$1"

    [[ -f "$ini_file" ]] || die "arquivo de chaves INI nao encontrado: $ini_file"

    mapfile -t DEEPL_API_KEYS < <(python3 - "$ini_file" <<'PY'
import configparser
import re
import sys

path = sys.argv[1]
cfg = configparser.ConfigParser(interpolation=None)
cfg.optionxform = str
loaded = cfg.read(path, encoding="utf-8")
if not loaded:
    sys.exit(0)

keys = []

def add_key(raw):
    value = (raw or "").strip().strip('"').strip("'")
    if value and value not in keys:
        keys.append(value)

for section in ("deepl_keys", "keys"):
    if cfg.has_section(section):
        for _, raw_value in cfg.items(section):
            add_key(raw_value)

if cfg.has_section("deepl"):
    for raw_name, raw_value in cfg.items("deepl"):
        key_name = raw_name.strip().lower()
        if key_name in {"api_key", "deepl_api_key", "key"}:
            add_key(raw_value)
        elif key_name == "api_keys":
            for part in re.split(r"[,\n;]+", raw_value or ""):
                add_key(part)

for key in keys:
    print(key)
PY
)

    if (( ${#DEEPL_API_KEYS[@]} == 0 )); then
        die "nenhuma chave DeepL valida encontrada em: $ini_file"
    fi
}

select_next_api_key() {
    local total_keys="${#DEEPL_API_KEYS[@]}"
    local attempts=0

    while (( attempts < total_keys )); do
        local current_index=$((CURRENT_KEY_INDEX % total_keys))
        local candidate_key="${DEEPL_API_KEYS[$current_index]}"
        local candidate_slot=$((current_index + 1))
        local candidate_prefix

        CURRENT_KEY_INDEX=$((CURRENT_KEY_INDEX + 1))
        attempts=$((attempts + 1))
        candidate_prefix="$(key_prefix8 "$candidate_key")"

        if is_key_blocked "$candidate_prefix"; then
            echo "==> Pulando chave (${candidate_slot}): ${candidate_prefix}(...) [bloqueada no estado]"
            continue
        fi

        ACTIVE_DEEPL_API_KEY="$candidate_key"
        ACTIVE_DEEPL_KEY_SLOT="$candidate_slot"
        return 0
    done

    return 1
}

key_prefix8() {
    local api_key="$1"
    printf '%.8s' "$api_key"
}

log_deepl_key_in_use() {
    local key_slot="$1"
    local api_key="$2"
    local prefix
    prefix="$(key_prefix8 "$api_key")"
    echo "Usando a chave (${key_slot}): ${prefix}(...)"
}

is_key_blocked() {
    local prefix="$1"
    local item
    for item in "${BLOCKED_KEY_PREFIXES[@]}"; do
        if [ "$item" = "$prefix" ]; then
            return 0
        fi
    done
    return 1
}

load_blocked_keys_state() {
    local state_file="$1"

    BLOCKED_KEY_PREFIXES=()
    if [ ! -f "$state_file" ]; then
        return 0
    fi

    mapfile -t BLOCKED_KEY_PREFIXES < <(python3 - "$state_file" <<'PY'
import configparser
import re
import sys

path = sys.argv[1]
cfg = configparser.ConfigParser(interpolation=None)
cfg.optionxform = str
cfg.read(path, encoding="utf-8")

if cfg.has_section("blocked_keys"):
    for raw_prefix in cfg.options("blocked_keys"):
        prefix = (raw_prefix or "").strip().lower()
        if re.fullmatch(r"[0-9a-f]{8}", prefix):
            print(prefix)
PY
)
}

persist_blocked_key_state() {
    local state_file="$1"
    local prefix="$2"
    local reason="$3"

    mkdir -p "$(dirname "$state_file")"

    python3 - "$state_file" "$prefix" "$reason" <<'PY'
import configparser
import sys
from datetime import datetime, timezone

path, prefix, reason = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = configparser.ConfigParser(interpolation=None)
cfg.optionxform = str
cfg.read(path, encoding="utf-8")

if not cfg.has_section("blocked_keys"):
    cfg.add_section("blocked_keys")

timestamp = datetime.now(timezone.utc).isoformat()
cfg.set("blocked_keys", prefix.lower(), f"{timestamp}|{reason}")

with open(path, "w", encoding="utf-8") as fh:
    cfg.write(fh)
PY
}

mark_key_as_quota_blocked() {
    local key_slot="$1"
    local api_key="$2"
    local reason="$3"
    local prefix

    prefix="$(key_prefix8 "$api_key")"
    if is_key_blocked "$prefix"; then
        return 0
    fi

    BLOCKED_KEY_PREFIXES+=("$prefix")
    persist_blocked_key_state "$DEEPL_KEYS_STATE_INI" "$prefix" "$reason"
    echo "==> Chave marcada como indisponivel por cota: (${key_slot}) ${prefix}(...)"
}

check_key_usage_available() {
    local api_key="$1"
    local usage_tmp
    local usage_http_code
    local usage_body
    local parsed
    local char_count
    local char_limit

    usage_tmp="$(mktemp)"
    usage_http_code=$(curl -sS \
        --max-time "$DEEPL_USAGE_TIMEOUT_SECONDS" \
        -X GET "$DEEPL_BASE/usage" \
        -H "Authorization: DeepL-Auth-Key $api_key" \
        -o "$usage_tmp" \
        -w "%{http_code}")
    usage_body="$(cat "$usage_tmp")"
    rm -f "$usage_tmp"

    case "$usage_http_code" in
        200)
            parsed=$(python3 - <<'PY' "$usage_body"
import json
import sys

raw = sys.argv[1]
try:
    payload = json.loads(raw)
except Exception:
    print("PARSE_ERROR")
    raise SystemExit(0)

character_count = payload.get("character_count")
character_limit = payload.get("character_limit")

def to_int(value):
    try:
        return int(value)
    except Exception:
        return -1

print(f"{to_int(character_count)}|{to_int(character_limit)}")
PY
)

            if [ "$parsed" = "PARSE_ERROR" ] || [ -z "$parsed" ]; then
                echo "unknown|unknown|parse_error"
                return 2
            fi

            char_count="${parsed%%|*}"
            char_limit="${parsed#*|}"

            if [ "$char_limit" -gt 0 ] && [ "$char_count" -ge "$char_limit" ]; then
                echo "exhausted|$char_count|$char_limit"
                return 1
            fi

            echo "available|$char_count|$char_limit"
            return 0
            ;;
        "$KEY_QUOTA_HTTP_CODE")
            echo "exhausted|http_$KEY_QUOTA_HTTP_CODE|http_$KEY_QUOTA_HTTP_CODE"
            return 1
            ;;
        403|401)
            echo "invalid|http_$usage_http_code|http_$usage_http_code"
            return 3
            ;;
        *)
            echo "unknown|http_$usage_http_code|http_$usage_http_code"
            return 2
            ;;
    esac
}

precheck_keys_usage() {
    local index
    local api_key
    local slot
    local prefix
    local status_line
    local status
    local count
    local limit
    local rc
    local available_count=0
    local exhausted_count=0
    local invalid_count=0
    local unknown_count=0
    local skipped_blocked_count=0
    local total_count="${#DEEPL_API_KEYS[@]}"

    echo "==> Checando disponibilidade de uso DeepL por chave..."

    for index in "${!DEEPL_API_KEYS[@]}"; do
        api_key="${DEEPL_API_KEYS[$index]}"
        slot=$((index + 1))
        prefix="$(key_prefix8 "$api_key")"

        if is_key_blocked "$prefix"; then
            echo "==> Pulando chave (${slot}): ${prefix}(...) [bloqueada no estado]"
            skipped_blocked_count=$((skipped_blocked_count + 1))
            continue
        fi

        status_line="$(check_key_usage_available "$api_key")"
        rc=$?
        status="${status_line%%|*}"
        count="$(printf '%s' "$status_line" | cut -d'|' -f2)"
        limit="$(printf '%s' "$status_line" | cut -d'|' -f3)"

        case "$rc" in
            0)
                available_count=$((available_count + 1))
                echo "==> Chave (${slot}) ${prefix}(...) disponivel | uso=${count}/${limit}"
                ;;
            1)
                echo "==> Chave (${slot}) ${prefix}(...) sem cota | uso=${count}/${limit}"
                mark_key_as_quota_blocked "$slot" "$api_key" "usage_exhausted"
                exhausted_count=$((exhausted_count + 1))
                ;;
            3)
                echo "==> Chave (${slot}) ${prefix}(...) invalida/sem permissao | detalhe=${count}"
                mark_key_as_quota_blocked "$slot" "$api_key" "usage_invalid"
                invalid_count=$((invalid_count + 1))
                ;;
            *)
                # Mantem a chave candidata quando a checagem de usage e inconclusiva.
                available_count=$((available_count + 1))
                unknown_count=$((unknown_count + 1))
                echo "==> Chave (${slot}) ${prefix}(...) sem resposta conclusiva em /usage | detalhe=${count}. Mantendo como tentativa."
                ;;
        esac
    done

    echo "==> Resumo de chaves DeepL: total=${total_count} disponiveis=${available_count} sem_cota=${exhausted_count} invalidas=${invalid_count} inconclusivas=${unknown_count} bloqueadas_estado=${skipped_blocked_count}"

    if [ "$available_count" -eq 0 ]; then
        die "Nenhuma chave DeepL disponivel apos pre-checagem de uso."
    fi
}

reset_blocked_keys_state() {
    local state_file="$1"
    BLOCKED_KEY_PREFIXES=()
    rm -f "$state_file"
}

translate_single_document() {
    local input_file="$1"
    local output_file="$2"
    local label="$3"
    local api_key="$4"
    local key_slot="$5"

    echo "==> Enviando '${label}' para o DeepL..."
    log_deepl_key_in_use "$key_slot" "$api_key"

    local upload_args=(
        -X POST "$DEEPL_BASE/document"
        -H "Authorization: DeepL-Auth-Key $api_key"
        -F "file=@$input_file"
        -F "target_lang=$TARGET_LANG_UPPER"
    )

    if [[ "$SOURCE_LANG_UPPER" != "AUTO" ]]; then
        upload_args+=( -F "source_lang=$SOURCE_LANG_UPPER" )
    fi

    local upload_response
    local upload_http_code
    local upload_tmp
    upload_tmp="$(mktemp)"
    upload_http_code=$(curl -sS "${upload_args[@]}" -o "$upload_tmp" -w "%{http_code}")
    upload_response="$(cat "$upload_tmp")"
    rm -f "$upload_tmp"

    if [ "$upload_http_code" = "$KEY_QUOTA_HTTP_CODE" ]; then
        echo "Aviso: DeepL retornou HTTP ${KEY_QUOTA_HTTP_CODE} no upload para esta chave."
        return "$KEY_QUOTA_RETURN_CODE"
    fi
    if [ "$upload_http_code" != "200" ]; then
        die "Upload falhou (HTTP $upload_http_code). Resposta da API:\n$upload_response"
    fi

    local document_id
    local document_key
    document_id=$(parse_json "$upload_response" "document_id")
    document_key=$(parse_json "$upload_response" "document_key")

    [[ -n "$document_id" ]] || die "Upload falhou. Resposta da API:\n$upload_response"
    [[ -n "$document_key" ]] || die "document_key ausente na resposta."

    echo "    Documento recebido. ID: $document_id"
    echo "==> Aguardando tradução..."

    while true; do
        local status_response
        local status
        local status_http_code
        local status_tmp
        log_deepl_key_in_use "$key_slot" "$api_key"
        status_tmp="$(mktemp)"
        status_http_code=$(curl -sS \
            -X POST "$DEEPL_BASE/document/$document_id" \
            -H "Authorization: DeepL-Auth-Key $api_key" \
            --data-urlencode "document_key=$document_key" \
            -o "$status_tmp" \
            -w "%{http_code}")
        status_response="$(cat "$status_tmp")"
        rm -f "$status_tmp"

        if [ "$status_http_code" = "$KEY_QUOTA_HTTP_CODE" ]; then
            echo "Aviso: DeepL retornou HTTP ${KEY_QUOTA_HTTP_CODE} na consulta de status para esta chave."
            return "$KEY_QUOTA_RETURN_CODE"
        fi
        if [ "$status_http_code" != "200" ]; then
            die "Consulta de status falhou (HTTP $status_http_code). Resposta: $status_response"
        fi

        status=$(parse_json "$status_response" "status")

        case "$status" in
            done)
                local chars
                chars=$(parse_json "$status_response" "billed_characters")
                echo "    Tradução concluída. Caracteres faturados: ${chars:-?}"
                break
                ;;
            error)
                local msg
                msg=$(parse_json "$status_response" "message")
                die "API retornou erro: ${msg:-desconhecido}"
                ;;
            queued|translating)
                local secs
                secs=$(parse_json "$status_response" "seconds_remaining")
                echo "    Status: $status | ~${secs:-?}s restantes. Verificando em ${POLL_INTERVAL}s..."
                sleep "$POLL_INTERVAL"
                ;;
            "")
                die "Resposta sem campo 'status'. Resposta: $status_response"
                ;;
            *)
                die "Status desconhecido: '$status'. Resposta: $status_response"
                ;;
        esac
    done

    echo "==> Baixando arquivo traduzido..."

    local http_code
    log_deepl_key_in_use "$key_slot" "$api_key"
    http_code=$(curl -sS \
        -X POST "$DEEPL_BASE/document/$document_id/result" \
        -H "Authorization: DeepL-Auth-Key $api_key" \
        --data-urlencode "document_key=$document_key" \
        -o "$output_file" \
        -w "%{http_code}")

    if [ "$http_code" = "$KEY_QUOTA_HTTP_CODE" ]; then
        rm -f "$output_file"
        echo "Aviso: DeepL retornou HTTP ${KEY_QUOTA_HTTP_CODE} no download para esta chave."
        return "$KEY_QUOTA_RETURN_CODE"
    fi

    [[ "$http_code" == "200" ]] || die "Download falhou (HTTP $http_code). O arquivo '$output_file' pode estar incompleto."
}

translate_with_key_failover() {
    local input_file="$1"
    local output_file="$2"
    local label="$3"
    local total_keys="${#DEEPL_API_KEYS[@]}"
    local attempts=0
    local rc

    while (( attempts < total_keys )); do
        if ! select_next_api_key; then
            die "Nenhuma chave DeepL disponivel. Verifique $DEEPL_KEYS_STATE_INI ou rode com --reset-keys-state."
        fi

        if translate_single_document "$input_file" "$output_file" "$label" "$ACTIVE_DEEPL_API_KEY" "$ACTIVE_DEEPL_KEY_SLOT"; then
            return 0
        else
            rc=$?
        fi

        if [ "$rc" -eq "$KEY_QUOTA_RETURN_CODE" ]; then
            mark_key_as_quota_blocked "$ACTIVE_DEEPL_KEY_SLOT" "$ACTIVE_DEEPL_API_KEY" "http_${KEY_QUOTA_HTTP_CODE}"
            attempts=$((attempts + 1))
            echo "==> Tentando proxima chave para continuar a traducao..."
            continue
        fi

        return "$rc"
    done

    die "Todas as chaves disponiveis retornaram HTTP ${KEY_QUOTA_HTTP_CODE}."
}

split_srt_into_parts() {
    local input_file="$1"
    local max_bytes="$2"
    local out_dir="$3"

    python3 - "$input_file" "$max_bytes" "$out_dir" <<'PY'
import re
import sys
from pathlib import Path

input_path = Path(sys.argv[1])
max_bytes = int(sys.argv[2])
out_dir = Path(sys.argv[3])
text = input_path.read_text(encoding="utf-8", errors="replace")

blocks = [b.strip("\n") for b in re.split(r"\n\s*\n", text.strip()) if b.strip()]
if not blocks:
    print("EMPTY")
    sys.exit(0)

parts = []
current = []
current_size = 0

for block in blocks:
    chunk = (block + "\n\n").encode("utf-8")
    size = len(chunk)
    if size > max_bytes:
        print(f"BLOCK_TOO_LARGE:{size}")
        sys.exit(2)

    if current and current_size + size > max_bytes:
        parts.append("".join(current).rstrip() + "\n")
        current = []
        current_size = 0

    current.append(block + "\n\n")
    current_size += size

if current:
    parts.append("".join(current).rstrip() + "\n")

for i, content in enumerate(parts, start=1):
    part_path = out_dir / f"part_{i:04d}.srt"
    part_path.write_text(content, encoding="utf-8")
    print(str(part_path))
PY
}

merge_srt_parts() {
    local output_file="$1"
    shift
        local part_file
        for part_file in "$@"; do
            if [ ! -f "$part_file" ]; then
                die "Parte traduzida ausente antes do merge: $part_file"
            fi
        done

    python3 - "$output_file" "$@" <<'PY'
import re
import sys
from pathlib import Path

output = Path(sys.argv[1])
inputs = [Path(p) for p in sys.argv[2:]]

blocks = []
for part in inputs:
    text = part.read_text(encoding="utf-8", errors="replace")
    part_blocks = [b.strip("\n") for b in re.split(r"\n\s*\n", text.strip()) if b.strip()]
    blocks.extend(part_blocks)

lines = []
for idx, block in enumerate(blocks, start=1):
    block_lines = block.splitlines()
    if not block_lines:
        continue
    while block_lines and re.fullmatch(r"\ufeff?\d+", block_lines[0].strip()):
        block_lines = block_lines[1:]
    if not block_lines:
        continue
    lines.append(str(idx))
    lines.extend(block_lines)
    lines.append("")

output.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY
}

usage() {
    echo "Uso: $0 [--keys-ini caminho.ini] [--keys-state-ini caminho.ini] [--reset-keys-state] [--source-lang ZH|ES|AUTO] [--target-lang PT-BR] <entrada.srt> [saida.srt]"
    echo "     Chaves DeepL devem estar no INI (secao [deepl_keys])."
}

# --- args ---
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-lang)
            shift
            [[ $# -gt 0 ]] || die "--source-lang exige valor"
            SOURCE_LANG="$1"
            ;;
        --target-lang)
            shift
            [[ $# -gt 0 ]] || die "--target-lang exige valor"
            TARGET_LANG="$1"
            ;;
        --keys-ini)
            shift
            [[ $# -gt 0 ]] || die "--keys-ini exige valor"
            DEEPL_KEYS_INI="$1"
            ;;
        --keys-state-ini)
            shift
            [[ $# -gt 0 ]] || die "--keys-state-ini exige valor"
            DEEPL_KEYS_STATE_INI="$1"
            ;;
        --reset-keys-state)
            RESET_KEYS_STATE=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --*)
            die "opcao desconhecida: $1"
            ;;
        *)
            POSITIONAL+=("$1")
            ;;
    esac
    shift
done

if [[ ${#POSITIONAL[@]} -lt 1 ]]; then
    usage
    exit 1
fi

INPUT_FILE="${POSITIONAL[0]}"
OUTPUT_FILE="${POSITIONAL[1]:-${INPUT_FILE%.srt}_pt-br.srt}"

SOURCE_LANG_UPPER="$(printf '%s' "$SOURCE_LANG" | tr '[:lower:]' '[:upper:]')"
TARGET_LANG_UPPER="$(printf '%s' "$TARGET_LANG" | tr '[:lower:]' '[:upper:]')"

case "$SOURCE_LANG_UPPER" in
    ZH|ES|AUTO)
        ;;
    *)
        die "source_lang invalido: $SOURCE_LANG (use ZH, ES ou AUTO)"
        ;;
esac

case "$TARGET_LANG_UPPER" in
    PT-BR|PT-PT)
        ;;
    *)
        die "target_lang invalido: $TARGET_LANG (use PT-BR ou PT-PT)"
        ;;
esac

[[ -f "$INPUT_FILE" ]] || die "arquivo '$INPUT_FILE' não encontrado."
[[ "$MAX_UPLOAD_BYTES" =~ ^[0-9]+$ ]] || die "DEEPL_DOC_MAX_BYTES invalido: $MAX_UPLOAD_BYTES"

load_deepl_keys_from_ini "$DEEPL_KEYS_INI"
echo "==> DeepL: ${#DEEPL_API_KEYS[@]} chave(s) carregada(s) de $DEEPL_KEYS_INI"

if [ "$RESET_KEYS_STATE" = "1" ]; then
    reset_blocked_keys_state "$DEEPL_KEYS_STATE_INI"
    echo "==> Estado de bloqueio de chaves resetado: $DEEPL_KEYS_STATE_INI"
fi

load_blocked_keys_state "$DEEPL_KEYS_STATE_INI"
if (( ${#BLOCKED_KEY_PREFIXES[@]} > 0 )); then
    echo "==> Chaves bloqueadas no estado: ${#BLOCKED_KEY_PREFIXES[@]} (arquivo: $DEEPL_KEYS_STATE_INI)"
fi

precheck_keys_usage

INPUT_SIZE_BYTES=$(file_size_bytes "$INPUT_FILE")

if (( INPUT_SIZE_BYTES <= MAX_UPLOAD_BYTES )); then
    translate_with_key_failover "$INPUT_FILE" "$OUTPUT_FILE" "$(basename "$INPUT_FILE")"
else
    echo "==> Arquivo maior que o limite por chamada (${MAX_UPLOAD_BYTES} bytes)."
    echo "==> Dividindo SRT em partes para envio ao DeepL..."

    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    SPLIT_OUTPUT=$(split_srt_into_parts "$INPUT_FILE" "$MAX_UPLOAD_BYTES" "$TMP_DIR")

    if [[ "$SPLIT_OUTPUT" == "EMPTY" ]]; then
        die "SRT de entrada vazio após normalização."
    fi
    if [[ "$SPLIT_OUTPUT" == BLOCK_TOO_LARGE:* ]]; then
        die "Um bloco SRT excede o limite de ${MAX_UPLOAD_BYTES} bytes (${SPLIT_OUTPUT#BLOCK_TOO_LARGE:})."
    fi

    mapfile -t PART_FILES <<< "$SPLIT_OUTPUT"
    (( ${#PART_FILES[@]} > 0 )) || die "Falha ao dividir SRT em partes."

    TRANSLATED_PARTS=()
    for i in "${!PART_FILES[@]}"; do
        PART_FILE="${PART_FILES[$i]}"
        PART_OUT="$TMP_DIR/translated_$(printf '%04d' "$((i + 1))").srt"
        PART_SIZE=$(file_size_bytes "$PART_FILE")
        echo "==> Parte $((i + 1))/${#PART_FILES[@]} (${PART_SIZE} bytes)"
        translate_with_key_failover "$PART_FILE" "$PART_OUT" "$(basename "$INPUT_FILE") [parte $((i + 1))/${#PART_FILES[@]}]"
        TRANSLATED_PARTS+=("$PART_OUT")
    done

    echo "==> Reagrupando partes traduzidas..."
    merge_srt_parts "$OUTPUT_FILE" "${TRANSLATED_PARTS[@]}"
fi

echo "==> Pronto! Arquivo salvo em: $OUTPUT_FILE"
