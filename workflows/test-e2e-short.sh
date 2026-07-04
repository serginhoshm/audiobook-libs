#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
TRANSLATION_BACKEND="${TRANSLATION_BACKEND:-google}"
NLLB_MODEL_DIR="${NLLB_MODEL_DIR:-$ROOT_DIR/models/nllb/facebook-nllb-200-distilled-600M}"
PIPER_BIN="${PIPER_BIN:-$ROOT_DIR/bin/piper}"
VOICE_MODEL="${VOICE_MODEL:-$ROOT_DIR/models/pt_BR-faber-medium.onnx}"
MODEL_SIZE="${MODEL_SIZE:-medium}"
INPUT_AUDIO="${INPUT_AUDIO:-$ROOT_DIR/e2e/e2e-test_spanish.wav}"
SOURCE_LANG="${SOURCE_LANG:-es}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/e2e}"
OUTPUT_PREFIX="${OUTPUT_PREFIX:-e2e-short}"
PAUSE_DURATION="${PAUSE_DURATION:-0.1}"

usage() {
  cat <<'EOF'
Uso: bash workflows/test-e2e-short.sh [opcoes]

Opcoes:
  --input <arquivo>          Audio/video curto de entrada (padrao: e2e/e2e-test_spanish.wav)
  --source-lang <lang>       Idioma de origem para traducao: es | zh-CN | auto (padrao: es)
  --backend <backend>        Backend de traducao: google | nllb_local | gemini (padrao: google)
  --out-dir <diretorio>      Diretorio de saida (padrao: e2e/)
  --prefix <nome>            Prefixo base dos artefatos (padrao: e2e-short)
  --model-size <size>        Modelo whisper (padrao: medium)
  --pause-duration <seg>     Pausa entre falas no piper (padrao: 0.1)
  --help                     Exibe esta ajuda

Saidas geradas:
  <out-dir>/<prefix>.srt
  <out-dir>/<prefix>.srtpt
  <out-dir>/<prefix>.pt.wav
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --input)
      shift
      INPUT_AUDIO="$1"
      ;;
    --source-lang)
      shift
      SOURCE_LANG="$1"
      ;;
    --backend)
      shift
      TRANSLATION_BACKEND="$1"
      ;;
    --out-dir)
      shift
      OUT_DIR="$1"
      ;;
    --prefix)
      shift
      OUTPUT_PREFIX="$1"
      ;;
    --model-size)
      shift
      MODEL_SIZE="$1"
      ;;
    --pause-duration)
      shift
      PAUSE_DURATION="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "[test-e2e-short] opcao invalida: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "[test-e2e-short] python nao encontrado: $PYTHON_BIN"
  exit 1
fi

if [[ ! -f "$INPUT_AUDIO" ]]; then
  echo "[test-e2e-short] arquivo de entrada nao encontrado: $INPUT_AUDIO"
  exit 1
fi

if [[ ! -x "$PIPER_BIN" ]]; then
  echo "[test-e2e-short] piper nao encontrado: $PIPER_BIN"
  exit 1
fi

if [[ ! -f "$VOICE_MODEL" ]]; then
  echo "[test-e2e-short] modelo de voz nao encontrado: $VOICE_MODEL"
  exit 1
fi

mkdir -p "$OUT_DIR"

case "$(printf '%s' "$SOURCE_LANG" | tr '[:upper:]' '[:lower:]')" in
  es)
    WHISPER_LANG="es"
    ;;
  zh-cn|zh)
    WHISPER_LANG="zh"
    SOURCE_LANG="zh-CN"
    ;;
  auto)
    WHISPER_LANG="auto"
    ;;
  *)
    echo "[test-e2e-short] source-lang invalido: $SOURCE_LANG (use es, zh-CN ou auto)"
    exit 1
    ;;
esac

TRANSCRIPT_SRT="$OUT_DIR/$OUTPUT_PREFIX.srt"
TRANSLATED_SRT="$OUT_DIR/$OUTPUT_PREFIX.srtpt"
OUTPUT_WAV="$OUT_DIR/$OUTPUT_PREFIX.pt.wav"

rm -f "$TRANSCRIPT_SRT" "$TRANSLATED_SRT" "$OUTPUT_WAV"

echo "[test-e2e-short] Etapa 1/6 - Transcricao"
"$PYTHON_BIN" -u "$ROOT_DIR/scripts/transcrever.py" \
  "$INPUT_AUDIO" \
  "$OUT_DIR" \
  "$WHISPER_LANG" \
  "$MODEL_SIZE" \
  "$OUTPUT_PREFIX"

echo "[test-e2e-short] Etapa 2/6 - Validacao da transcricao"
"$PYTHON_BIN" "$ROOT_DIR/scripts/pipeline_validators.py" validate-transcription \
  --audio "$INPUT_AUDIO" \
  --srt "$TRANSCRIPT_SRT" \
  --tolerance 5.0

echo "[test-e2e-short] Etapa 3/6 - Traducao ($TRANSLATION_BACKEND)"
"$PYTHON_BIN" "$ROOT_DIR/scripts/traduzir.py" \
  "$TRANSCRIPT_SRT" \
  "$TRANSLATED_SRT" \
  "$SOURCE_LANG" \
  --backend "$TRANSLATION_BACKEND" \
  --nllb-model-dir "$NLLB_MODEL_DIR"

echo "[test-e2e-short] Etapa 4/6 - Validacao da traducao"
"$PYTHON_BIN" "$ROOT_DIR/scripts/pipeline_validators.py" validate-translation \
  --source-srt "$TRANSCRIPT_SRT" \
  --target-srt "$TRANSLATED_SRT" \
  --tolerance 0.5

echo "[test-e2e-short] Etapa 5/6 - Geracao de audio"
"$PYTHON_BIN" -u "$ROOT_DIR/scripts/gerar-sincronizado.py" \
  --srt "$TRANSLATED_SRT" \
  --output "$OUTPUT_WAV" \
  --model "$VOICE_MODEL" \
  --piper "$PIPER_BIN" \
  --source_lang "$SOURCE_LANG" \
  --pause_duration "$PAUSE_DURATION"

echo "[test-e2e-short] Etapa 6/6 - Validacao do audio"
"$PYTHON_BIN" "$ROOT_DIR/scripts/pipeline_validators.py" validate-generated-audio \
  --srt "$TRANSLATED_SRT" \
  --audio "$OUTPUT_WAV" \
  --tolerance 1.5

echo "[test-e2e-short] Concluido"
echo "[test-e2e-short] SRT: $TRANSCRIPT_SRT"
echo "[test-e2e-short] SRT traduzido: $TRANSLATED_SRT"
echo "[test-e2e-short] WAV: $OUTPUT_WAV"
