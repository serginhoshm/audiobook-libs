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

# --- 1. Upload ---
echo "==> Enviando '$(basename "$INPUT_FILE")' para o DeepL..."

UPLOAD_ARGS=(
    -X POST "$DEEPL_BASE/document"
    -H "Authorization: DeepL-Auth-Key $DEEPL_API_KEY"
    -F "file=@$INPUT_FILE"
    -F "target_lang=$TARGET_LANG_UPPER"
)

if [[ "$SOURCE_LANG_UPPER" != "AUTO" ]]; then
    UPLOAD_ARGS+=( -F "source_lang=$SOURCE_LANG_UPPER" )
fi

UPLOAD_RESPONSE=$(curl -sS \
    "${UPLOAD_ARGS[@]}")

DOCUMENT_ID=$(parse_json "$UPLOAD_RESPONSE" "document_id")
DOCUMENT_KEY=$(parse_json "$UPLOAD_RESPONSE" "document_key")

[[ -n "$DOCUMENT_ID" ]] || die "Upload falhou. Resposta da API:\n$UPLOAD_RESPONSE"
[[ -n "$DOCUMENT_KEY" ]] || die "document_key ausente na resposta."

echo "    Documento recebido. ID: $DOCUMENT_ID"

# --- 2. Polling de status ---
echo "==> Aguardando tradução..."

while true; do
    STATUS_RESPONSE=$(curl -sS \
        -X POST "$DEEPL_BASE/document/$DOCUMENT_ID" \
        -H "Authorization: DeepL-Auth-Key $DEEPL_API_KEY" \
        --data-urlencode "document_key=$DOCUMENT_KEY")

    STATUS=$(parse_json "$STATUS_RESPONSE" "status")

    case "$STATUS" in
        done)
            CHARS=$(parse_json "$STATUS_RESPONSE" "billed_characters")
            echo "    Tradução concluída. Caracteres faturados: ${CHARS:-?}"
            break
            ;;
        error)
            MSG=$(parse_json "$STATUS_RESPONSE" "message")
            die "API retornou erro: ${MSG:-desconhecido}"
            ;;
        queued|translating)
            SECS=$(parse_json "$STATUS_RESPONSE" "seconds_remaining")
            echo "    Status: $STATUS | ~${SECS:-?}s restantes. Verificando em ${POLL_INTERVAL}s..."
            sleep "$POLL_INTERVAL"
            ;;
        "")
            die "Resposta sem campo 'status'. Resposta: $STATUS_RESPONSE"
            ;;
        *)
            die "Status desconhecido: '$STATUS'. Resposta: $STATUS_RESPONSE"
            ;;
    esac
done

# --- 3. Download ---
echo "==> Baixando arquivo traduzido..."

HTTP_CODE=$(curl -sS \
    -X POST "$DEEPL_BASE/document/$DOCUMENT_ID/result" \
    -H "Authorization: DeepL-Auth-Key $DEEPL_API_KEY" \
    --data-urlencode "document_key=$DOCUMENT_KEY" \
    -o "$OUTPUT_FILE" \
    -w "%{http_code}")

[[ "$HTTP_CODE" == "200" ]] || die "Download falhou (HTTP $HTTP_CODE). O arquivo '$OUTPUT_FILE' pode estar incompleto."

echo "==> Pronto! Arquivo salvo em: $OUTPUT_FILE"
