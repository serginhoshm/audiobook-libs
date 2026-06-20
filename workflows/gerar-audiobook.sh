#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
SRT_ENTRADA="$ROOT_DIR/data/outputs/output.srt"
PIPER_BIN="$ROOT_DIR/bin/piper"
MODELS_DIR="$ROOT_DIR/data/models"
OUTPUT_DIR="$ROOT_DIR/data/outputs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "🎙️  GERADOR DE AUDIOBOOK"
echo "==============================================================="

# Seleção de Voz
echo "A) Faber (Masculino) | B) Gisela (Feminino)"
read -p "Voz [A]: " OP_V
if [[ "$OP_V" =~ ^[Bb]$ ]]; then
    MODELO="pt_BR-gisela-medium.onnx"
    URL="https://huggingface.co/datasets/piper/resolve/main/pt/pt_BR/gisela/medium"
else
    MODELO="pt_BR-faber-medium.onnx"
    URL="https://huggingface.co/datasets/piper/resolve/main/pt/pt_BR/faber/medium"
fi

# Download do modelo se não existir
mkdir -p "$MODELS_DIR"
[ ! -f "$MODELS_DIR/$MODELO" ] && wget -c "$URL/$MODELO" -O "$MODELS_DIR/$MODELO"
[ ! -f "$MODELS_DIR/$MODELO.json" ] && wget -c "$URL/$MODELO.json" -O "$MODELS_DIR/$MODELO.json"

SAIDA="$OUTPUT_DIR/output_${TIMESTAMP}.wav"

echo "⏳ Gerando áudio sincronizado... Por favor aguarde."

$PYTHON_BIN scripts/gerar-sincronizado.py \
    --srt "$SRT_ENTRADA" \
    --output "$SAIDA" \
    --model "$MODELS_DIR/$MODELO" \
    --piper "$PIPER_BIN" \
    --pause_duration 0.1

echo "==============================================================="
echo "✅ SUCESSO: $SAIDA"

