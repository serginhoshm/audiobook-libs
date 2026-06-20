#!/usr/bin/env bash

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Setup logging
mkdir -p "$ROOT_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$ROOT_DIR/logs/transcrever-${TIMESTAMP}.log"
SCRIPT_NAME="transcrever"
SCRIPT_START_TIME=$(date +%s)

# Source logging functions
source "$ROOT_DIR/scripts/log_helpers.sh"

{

if [ ! -d ".venv" ]; then
    log_error "Ambiente virtual não encontrado."
    log_summary "FALHA" "Ambiente Python não configurado"
    exit 1
fi

log_header
log_section "Verificação de Pré-requisitos"
log_step "Validando arquivo de entrada"
LINGUA="es"
INPUT_AUDIO="$ROOT_DIR/data/inputs/audio_entrada.mp3"
OUTPUT_DIR="$ROOT_DIR/data/outputs"

if [ ! -f "$INPUT_AUDIO" ]; then
    log_error "Arquivo de áudio não encontrado em $INPUT_AUDIO"
    log_summary "FALHA" "Arquivo de entrada ausente"
    exit 1
fi

log_step "Arquivo de entrada válido"
log_section "Transcrição de Áudio"

mkdir -p "$OUTPUT_DIR"
log_step "Iniciando transcrição..."
from faster_whisper import WhisperModel
from pathlib import Path
import json
import sys

MODEL_SIZE = sys.argv[1]
LANGUAGE = sys.argv[2]
INPUT_FILE = sys.argv[3]
OUTPUT_DIR = Path(sys.argv[4])


def srt_time(sec):
    h = int(sec // 3600)
    m = int((sec % 3600) // 60)
    s = int(sec % 60)
    ms = int((sec - int(sec)) * 1000)
    return f"{h:02}:{m:02}:{s:02},{ms:03}"


def vtt_time(sec):
    h = int(sec // 3600)
    m = int((sec % 3600) // 60)
    s = int(sec % 60)
    ms = int((sec - int(sec)) * 1000)
    return f"{h:02}:{m:02}:{s:02}.{ms:03}"


audio = Path(INPUT_FILE)
base = OUTPUT_DIR / audio.stem

print(f"\nProcessando {audio.name}")

model = WhisperModel(
    MODEL_SIZE,
    device="cpu",
    compute_type="int8"
)

segments, info = model.transcribe(
    str(audio),
    language=LANGUAGE,
    beam_size=5,
    vad_filter=True
)

segments = list(segments)

with open(base.with_suffix(".txt"), "w", encoding="utf-8") as f:
    for seg in segments:
        f.write(seg.text.strip() + "\n")

with open(base.with_suffix(".srt"), "w", encoding="utf-8") as f:
    for n, seg in enumerate(segments, start=1):
        f.write(f"{n}\n")
        f.write(f"{srt_time(seg.start)} --> {srt_time(seg.end)}\n")
        f.write(seg.text.strip() + "\n\n")

with open(base.with_suffix(".vtt"), "w", encoding="utf-8") as f:
    f.write("WEBVTT\n\n")
    for seg in segments:
        f.write(
            f"{vtt_time(seg.start)} --> "
            f"{vtt_time(seg.end)}\n"
        )
        f.write(seg.text.strip() + "\n\n")

with open(base.with_suffix(".tsv"), "w", encoding="utf-8") as f:
    f.write("start\tend\ttext\n")
    for seg in segments:
        texto = seg.text.replace("\n", " ")
        f.write(
            f"{seg.start:.3f}\t"
            f"{seg.end:.3f}\t"
            f"{texto}\n"
        )

data = {
    "language": info.language,
    "language_probability": info.language_probability,
    "segments": [
        {
            "start": seg.start,
            "end": seg.end,
            "text": seg.text.strip()
        }
        for seg in segments
    ]
}

with open(base.with_suffix(".json"), "w", encoding="utf-8") as f:
    json.dump(
        data,
        f,
        ensure_ascii=False,
        indent=2
    )

print(f"Concluído: {audio.name}")
PYTHON

python .transcrever.py \
    "$MODELO" \
    "$LINGUA" \
    "$INPUT_AUDIO" \
    "$OUTPUT_DIR"

rm -f .transcrever.py

log_step "Processamento concluído"
log_summary "SUCCESS" ""
} 2>&1 | tee -a "$LOG_FILE"

