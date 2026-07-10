#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: bash workflows/srt_equalizer.sh <input.srt|input.srtpt>

Environment variables:
  PYTHON_BIN                  Python executable to use (default: .venv/bin/python or python3)
  SRT_EQUALIZER_METHOD        Split method: punctuation, halving, or greedy (default: punctuation)
  SRT_EQUALIZER_TARGET_CHARS  Maximum characters per fragment (default: 42)
  SRT_EQUALIZER_EXTRA_PYTHONPATH  Extra path to prepend to PYTHONPATH (for local checkouts)

Example:
  bash workflows/srt_equalizer.sh data_test/published/ABelaAdormecida.srtpt
EOF
}

if [ "${1:-}" = "" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

INPUT_SRT="$1"
if [ ! -f "$INPUT_SRT" ]; then
  echo "[srt_equalizer] input file not found: $INPUT_SRT" >&2
  exit 1
fi

PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="$(command -v python3 || true)"
fi

if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
  echo "[srt_equalizer] no usable Python interpreter found" >&2
  exit 1
fi

METHOD="${SRT_EQUALIZER_METHOD:-punctuation}"
TARGET_CHARS="${SRT_EQUALIZER_TARGET_CHARS:-42}"

case "$METHOD" in
  punctuation|halving|greedy)
    ;;
  *)
    echo "[srt_equalizer] invalid method: $METHOD" >&2
    echo "[srt_equalizer] expected one of: punctuation, halving, greedy" >&2
    exit 1
    ;;
esac

if ! [[ "$TARGET_CHARS" =~ ^[0-9]+$ ]]; then
  echo "[srt_equalizer] SRT_EQUALIZER_TARGET_CHARS must be an integer: $TARGET_CHARS" >&2
  exit 1
fi

INPUT_ABS="$ROOT_DIR/$INPUT_SRT"
if [[ "$INPUT_SRT" = /* ]]; then
  INPUT_ABS="$INPUT_SRT"
fi

export PYTHONPATH="${SRT_EQUALIZER_EXTRA_PYTHONPATH:-}${PYTHONPATH:+:$PYTHONPATH}"

"$PYTHON_BIN" - "$INPUT_ABS" "$METHOD" "$TARGET_CHARS" <<'PY'
from pathlib import Path
import sys
import os

input_path = Path(sys.argv[1]).resolve()
method = sys.argv[2]
target_chars = int(sys.argv[3])

suffix = ''.join(input_path.suffixes)
stem = input_path.name[:-len(suffix)] if suffix else input_path.name
output_name = f"{stem} (improved){suffix}"

os.chdir(input_path.parent)

try:
    from srt_equalizer import srt_equalizer as equalizer
except Exception as exc:
  raise SystemExit(
    "[srt_equalizer] could not import srt_equalizer. "
    "Install it in the active environment or set SRT_EQUALIZER_EXTRA_PYTHONPATH."
  ) from exc

equalizer.equalize_srt_file(input_path.name, output_name, target_chars, method=method)
print(f"[srt_equalizer] wrote: {input_path.parent / output_name}")
PY