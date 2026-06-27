#!/usr/bin/env bash
# translate_srt.sh — Traduz arquivo SRT via DeepL API (document translation).
#
# Uso:
#   ./translate_srt.sh [--source-lang ZH|ES|AUTO] [--target-lang PT-BR] <entrada.srt> [saida.srt]
#
# Chave:
#   export DEEPL_API_KEY="sua-chave-aqui"
#
# Dependencias: curl, python3 (stdlib apenas)

set -euo pipefail

DEEPL_BASE="${DEEPL_BASE:-https://api-free.deepl.com/v2}"
SOURCE_LANG="${SOURCE_LANG:-ZH}"
TARGET_LANG="${TARGET_LANG:-PT-BR}"
POLL_INTERVAL=5
MAX_UPLOAD_BYTES="${DEEPL_DOC_MAX_BYTES:-81920}"

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

translate_single_document() {
    local input_file="$1"
    local output_file="$2"
    local label="$3"

    echo "==> Enviando '${label}' para o DeepL..."

    local upload_args=(
        -X POST "$DEEPL_BASE/document"
        -H "Authorization: DeepL-Auth-Key $DEEPL_API_KEY"
        -F "file=@$input_file"
        -F "target_lang=$TARGET_LANG_UPPER"
    )

    if [[ "$SOURCE_LANG_UPPER" != "AUTO" ]]; then
        upload_args+=( -F "source_lang=$SOURCE_LANG_UPPER" )
    fi

    local upload_response
    upload_response=$(curl -sS "${upload_args[@]}")

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
        status_response=$(curl -sS \
            -X POST "$DEEPL_BASE/document/$document_id" \
            -H "Authorization: DeepL-Auth-Key $DEEPL_API_KEY" \
            --data-urlencode "document_key=$document_key")

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
    http_code=$(curl -sS \
        -X POST "$DEEPL_BASE/document/$document_id/result" \
        -H "Authorization: DeepL-Auth-Key $DEEPL_API_KEY" \
        --data-urlencode "document_key=$document_key" \
        -o "$output_file" \
        -w "%{http_code}")

    [[ "$http_code" == "200" ]] || die "Download falhou (HTTP $http_code). O arquivo '$output_file' pode estar incompleto."
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
    echo "Uso: $0 [--source-lang ZH|ES|AUTO] [--target-lang PT-BR] <entrada.srt> [saida.srt]"
    echo "     DEEPL_API_KEY deve estar definida no ambiente."
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
[[ -n "${DEEPL_API_KEY:-}" ]] || die "DEEPL_API_KEY não definida. Obtenha gratuitamente em https://www.deepl.com/pro-api"
[[ "$MAX_UPLOAD_BYTES" =~ ^[0-9]+$ ]] || die "DEEPL_DOC_MAX_BYTES invalido: $MAX_UPLOAD_BYTES"

INPUT_SIZE_BYTES=$(file_size_bytes "$INPUT_FILE")

if (( INPUT_SIZE_BYTES <= MAX_UPLOAD_BYTES )); then
    translate_single_document "$INPUT_FILE" "$OUTPUT_FILE" "$(basename "$INPUT_FILE")"
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
        translate_single_document "$PART_FILE" "$PART_OUT" "$(basename "$INPUT_FILE") [parte $((i + 1))/${#PART_FILES[@]}]"
        TRANSLATED_PARTS+=("$PART_OUT")
    done

    echo "==> Reagrupando partes traduzidas..."
    merge_srt_parts "$OUTPUT_FILE" "${TRANSLATED_PARTS[@]}"
fi

echo "==> Pronto! Arquivo salvo em: $OUTPUT_FILE"
