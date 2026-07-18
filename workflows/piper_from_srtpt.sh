#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
DATA_ROOT="$(python3 "$ROOT_DIR/scripts/resolve_data_root.py" data-root)"

usage() {
  cat <<'EOF'
Usage: bash workflows/piper_from_srtpt.sh <input.srtpt>

Environment variables:
  PYTHON_BIN           Python executable to use (default: .venv/bin/python or python3)
  PIPER_SCRIPT         Path to the synthesis script (default: scripts/gerar-sincronizado.py)
  PIPER_BIN            Piper executable (default: bin/piper)
  PIPER_MODEL          Piper voice model (default: models/pt_BR-faber-medium.onnx)
  PIPER_PAUSE_DURATION Pause duration between subtitles in seconds (default: 0.1)
  PIPER_SOURCE_LANG    Source language hint passed to the synthesis script (default: auto)

Example:
  bash workflows/piper_from_srtpt.sh /path/to/book.srtpt
EOF
}

if [ "${1:-}" = "" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

INPUT_SRTPT="$1"
INPUT_PATH="$INPUT_SRTPT"
if [[ "$INPUT_SRTPT" != /* ]]; then
  INPUT_PATH="$DATA_ROOT/$INPUT_SRTPT"
fi

if [ ! -f "$INPUT_PATH" ]; then
  echo "[piper_from_srtpt] input file not found: $INPUT_PATH" >&2
  exit 1
fi

case "$INPUT_SRTPT" in
  *.srtpt|*.srt)
    ;;
  *)
    echo "[piper_from_srtpt] expected an .srtpt file, got: $INPUT_SRTPT" >&2
    exit 1
    ;;
esac

PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="$(command -v python3 || true)"
fi

if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
  echo "[piper_from_srtpt] no usable Python interpreter found" >&2
  exit 1
fi

PIPER_SCRIPT="${PIPER_SCRIPT:-$ROOT_DIR/scripts/gerar-sincronizado.py}"
PIPER_BIN="${PIPER_BIN:-$ROOT_DIR/bin/piper}"
PIPER_MODEL="${PIPER_MODEL:-$ROOT_DIR/models/pt_BR-faber-medium.onnx}"
PIPER_PAUSE_DURATION="${PIPER_PAUSE_DURATION:-0.1}"
PIPER_SOURCE_LANG="${PIPER_SOURCE_LANG:-auto}"

if [ ! -f "$PIPER_SCRIPT" ]; then
  echo "[piper_from_srtpt] synthesis script not found: $PIPER_SCRIPT" >&2
  exit 1
fi
if [ ! -x "$PIPER_BIN" ]; then
  echo "[piper_from_srtpt] Piper executable not found: $PIPER_BIN" >&2
  exit 1
fi
if [ ! -f "$PIPER_MODEL" ]; then
  echo "[piper_from_srtpt] Piper model not found: $PIPER_MODEL" >&2
  exit 1
fi

INPUT_ABS="$(realpath "$INPUT_PATH")"
INPUT_DIR="$(dirname "$INPUT_ABS")"
INPUT_BASE="$(basename "$INPUT_ABS")"
OUTPUT_WAV="$INPUT_DIR/${INPUT_BASE%.*}.wav"

if [ -e "$OUTPUT_WAV" ]; then
  rm -f "$OUTPUT_WAV"
fi

ARGS=(
  "$PIPER_SCRIPT"
  --srt "$INPUT_ABS"
  --output "$OUTPUT_WAV"
  --model "$PIPER_MODEL"
  --piper "$PIPER_BIN"
  --pause_duration "$PIPER_PAUSE_DURATION"
  --source_lang "$PIPER_SOURCE_LANG"
)

"$PYTHON_BIN" "${ARGS[@]}"

echo "[piper_from_srtpt] wrote: $OUTPUT_WAV"