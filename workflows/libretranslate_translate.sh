#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
DATA_ROOT="$(python3 "$ROOT_DIR/scripts/resolve_data_root.py" data-root)"

usage() {
  cat <<'EOF'
Usage: bash workflows/libretranslate_translate.sh <input.srt>

Environment variables:
  PYTHON_BIN                     Python executable to use (default: .venv/bin/python or python3)
  LIBRETRANSLATE_DIR             Local LibreTranslate checkout (default: external/LibreTranslate)
  LIBRETRANSLATE_VENV_DIR        Virtualenv directory for LibreTranslate (default: <checkout>/.venv)
  LIBRETRANSLATE_URL             Base URL of the LibreTranslate server (default: http://127.0.0.1:5000)
  LIBRETRANSLATE_TARGET_LANG     Target language code (default: pt)
  LIBRETRANSLATE_DETECT_SAMPLE_CHARS  Number of characters used for language detection (default: 4000)
  LIBRETRANSLATE_TIMEOUT_SECONDS  HTTP timeout in seconds (default: 30)
  LIBRETRANSLATE_LOAD_ONLY_LANG_CODES  Optional comma-separated codes used when auto-starting the server

Example:
  bash workflows/libretranslate_translate.sh /path/to/book.srt
EOF
}

if [ "${1:-}" = "" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

INPUT_SRT="$1"
INPUT_PATH="$INPUT_SRT"
if [[ "$INPUT_SRT" != /* ]]; then
  INPUT_PATH="$DATA_ROOT/$INPUT_SRT"
fi

if [ ! -f "$INPUT_PATH" ]; then
  echo "[libretranslate] input file not found: $INPUT_PATH" >&2
  exit 1
fi

case "$INPUT_SRT" in
  *.srt)
    ;;
  *)
    echo "[libretranslate] expected an .srt file, got: $INPUT_SRT" >&2
    exit 1
    ;;
esac

PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="$(command -v python3 || true)"
fi

if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
  echo "[libretranslate] no usable Python interpreter found" >&2
  exit 1
fi

LIBRETRANSLATE_DIR="${LIBRETRANSLATE_DIR:-$ROOT_DIR/external/LibreTranslate}"
LIBRETRANSLATE_VENV_DIR="${LIBRETRANSLATE_VENV_DIR:-$LIBRETRANSLATE_DIR/.venv}"
LIBRETRANSLATE_URL="${LIBRETRANSLATE_URL:-http://127.0.0.1:5000}"
LIBRETRANSLATE_TARGET_LANG="${LIBRETRANSLATE_TARGET_LANG:-pt}"
LIBRETRANSLATE_DETECT_SAMPLE_CHARS="${LIBRETRANSLATE_DETECT_SAMPLE_CHARS:-4000}"
LIBRETRANSLATE_TIMEOUT_SECONDS="${LIBRETRANSLATE_TIMEOUT_SECONDS:-30}"
LIBRETRANSLATE_LOAD_ONLY_LANG_CODES="${LIBRETRANSLATE_LOAD_ONLY_LANG_CODES:-en,es,zh,pt}"

if ! [[ "$LIBRETRANSLATE_DETECT_SAMPLE_CHARS" =~ ^[0-9]+$ ]]; then
  echo "[libretranslate] LIBRETRANSLATE_DETECT_SAMPLE_CHARS must be an integer" >&2
  exit 1
fi

if ! [[ "$LIBRETRANSLATE_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "[libretranslate] LIBRETRANSLATE_TIMEOUT_SECONDS must be an integer" >&2
  exit 1
fi

if [ ! -d "$LIBRETRANSLATE_DIR" ]; then
  echo "[libretranslate] LibreTranslate checkout not found: $LIBRETRANSLATE_DIR" >&2
  echo "[libretranslate] run: bash setup/libretranslate/setup_libretranslate.sh" >&2
  exit 1
fi

SERVER_WAS_STARTED="0"
SERVER_PID=""

server_is_ready() {
  "$PYTHON_BIN" - "$LIBRETRANSLATE_URL" <<'PY' >/dev/null 2>&1
from urllib import request
import sys

url = sys.argv[1].rstrip("/") + "/languages"
request.urlopen(url, timeout=2).read()
PY
}

start_server_if_needed() {
  if server_is_ready; then
    return 0
  fi

  if [ ! -x "$LIBRETRANSLATE_VENV_DIR/bin/libretranslate" ]; then
    echo "[libretranslate] libretranslate executable not found in $LIBRETRANSLATE_VENV_DIR/bin" >&2
    echo "[libretranslate] run setup first: bash setup/libretranslate/setup_libretranslate.sh" >&2
    exit 1
  fi

  echo "[libretranslate] starting local server..."
  SERVER_WAS_STARTED="1"
  if [ -n "${LIBRETRANSLATE_LOAD_ONLY_LANG_CODES:-}" ]; then
    "$LIBRETRANSLATE_VENV_DIR/bin/libretranslate" --host 127.0.0.1 --port 5000 --load-only "$LIBRETRANSLATE_LOAD_ONLY_LANG_CODES" >/tmp/libretranslate.log 2>&1 &
  else
    "$LIBRETRANSLATE_VENV_DIR/bin/libretranslate" --host 127.0.0.1 --port 5000 >/tmp/libretranslate.log 2>&1 &
  fi
  SERVER_PID="$!"

  for _ in $(seq 1 60); do
    if server_is_ready; then
      return 0
    fi
    sleep 1
  done

  echo "[libretranslate] server did not become ready in time" >&2
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  exit 1
}

cleanup() {
  if [ "$SERVER_WAS_STARTED" = "1" ] && [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

INPUT_ABS="$(realpath "$INPUT_PATH")"
INPUT_DIR="$(dirname "$INPUT_ABS")"
INPUT_BASE="$(basename "$INPUT_ABS")"
OUTPUT_SRTPT="$INPUT_DIR/${INPUT_BASE%.*}.srtpt"

if [ -e "$OUTPUT_SRTPT" ]; then
  rm -f "$OUTPUT_SRTPT"
fi

start_server_if_needed

"$PYTHON_BIN" - "$INPUT_ABS" "$OUTPUT_SRTPT" "$LIBRETRANSLATE_URL" "$LIBRETRANSLATE_TARGET_LANG" "$LIBRETRANSLATE_DETECT_SAMPLE_CHARS" "$LIBRETRANSLATE_TIMEOUT_SECONDS" <<'PY'
from pathlib import Path
import json
import sys
from urllib import error, parse, request

import pysrt

input_path = Path(sys.argv[1]).resolve()
output_path = Path(sys.argv[2]).resolve()
base_url = sys.argv[3].rstrip("/")
target_lang = sys.argv[4]
sample_chars = int(sys.argv[5])
timeout = int(sys.argv[6])


def normalize_text(text: str) -> str:
    return " ".join((text or "").replace("\r", " ").replace("\n", " ").split())


def post_json(path: str, payload: dict) -> dict | list:
    data = json.dumps(payload).encode("utf-8")
    req = request.Request(
        f"{base_url}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def load_subtitles(path: Path):
    for encoding in ("utf-8", "iso-8859-1"):
        try:
            return pysrt.open(str(path), encoding=encoding)
        except Exception:
            continue
    raise RuntimeError(f"Unable to read subtitle file: {path}")


def detect_language(sample_text: str) -> str:
    if not sample_text.strip():
        return "auto"

    try:
        detections = post_json("/detect", {"q": sample_text})
    except Exception:
        return "auto"

    if not detections:
        return "auto"

    language = str(detections[0].get("language") or "auto").strip()
    return language or "auto"


def translate_text(text: str, source_lang: str) -> str:
    payload = {
        "q": text,
        "source": source_lang,
        "target": target_lang,
        "format": "text",
    }

    try:
        response = post_json("/translate", payload)
    except error.HTTPError as exc:
        if source_lang != "auto":
            payload["source"] = "auto"
            response = post_json("/translate", payload)
        else:
            raise RuntimeError(f"Translation failed: HTTP {exc.code}") from exc
    except error.URLError as exc:
        raise RuntimeError(f"Translation failed: {exc}") from exc

    translated = normalize_text(str(response.get("translatedText", "")))
    if not translated:
        raise RuntimeError("Translation failed: empty response")
    return translated


subtitles = load_subtitles(input_path)
sample_text = " ".join(
    normalize_text(sub.text)
    for sub in subtitles
    if normalize_text(sub.text)
)
sample_text = sample_text[:sample_chars]
source_lang = detect_language(sample_text)

for sub in subtitles:
    text = normalize_text(sub.text)
    if not text:
        continue
    sub.text = translate_text(text, source_lang)

output_path.parent.mkdir(parents=True, exist_ok=True)
subtitles.save(str(output_path), encoding="utf-8")

print(f"[libretranslate] detected source: {source_lang}")
print(f"[libretranslate] wrote: {output_path}")
PY
