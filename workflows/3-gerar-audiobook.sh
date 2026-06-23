#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
PIPER_BIN="${PIPER_BIN:-$ROOT_DIR/bin/piper}"
MODELS_DIR="$ROOT_DIR/data/models"
OUTPUT_DIR="$ROOT_DIR/data/outputs"
INPUT_SRT="${1:-}"
OUTPUT_WAV="${2:-}"

if [ -z "$INPUT_SRT" ]; then
    echo "Uso: $0 <arquivo_srt> [arquivo_wav_saida]"
    echo "Exemplo: $0 data/e2e/audio_model.pt.srt data/e2e/audio_model.wav"
    exit 1
fi

if [ ! -f "$INPUT_SRT" ]; then
    echo "Arquivo SRT não encontrado em $INPUT_SRT"
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "🎙️  GERADOR DE AUDIOBOOK"
echo "==============================================================="

echo "A) Faber (Masculino) | B) Gisela (Feminino)"
read -p "Voz [A]: " OP_V
if [[ "$OP_V" =~ ^[Bb]$ ]]; then
    MODELO="pt_BR-gisela-medium.onnx"
    URL="https://huggingface.co/datasets/piper/resolve/main/pt/pt_BR/gisela/medium"
else
    MODELO="pt_BR-faber-medium.onnx"
    URL="https://huggingface.co/datasets/piper/resolve/main/pt/pt_BR/faber/medium"
fi

mkdir -p "$MODELS_DIR" "$OUTPUT_DIR"
[ ! -f "$MODELS_DIR/$MODELO" ] && wget -c "$URL/$MODELO" -O "$MODELS_DIR/$MODELO"
[ ! -f "$MODELS_DIR/$MODELO.json" ] && wget -c "$URL/$MODELO.json" -O "$MODELS_DIR/$MODELO.json"

SAIDA="${OUTPUT_WAV:-$OUTPUT_DIR/output_${TIMESTAMP}.wav}"
mkdir -p "$(dirname "$SAIDA")"

echo "⏳ Gerando áudio sincronizado... Por favor aguarde."

$PYTHON_BIN scripts/gerar-sincronizado.py \
    --srt "$INPUT_SRT" \
    --output "$SAIDA" \
    --model "$MODELS_DIR/$MODELO" \
    --piper "$PIPER_BIN" \
    --pause_duration 0.1

echo "==============================================================="
echo "✅ SUCESSO: $SAIDA"

