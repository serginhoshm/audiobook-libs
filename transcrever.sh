#!/usr/bin/env bash

set -e

if [ ! -d ".venv" ]; then
    echo "Ambiente não encontrado."
    echo "Execute primeiro:"
    echo "./setup.sh"
    exit 1
fi

source .venv/bin/activate

MODELO="medium"
LINGUA="es"

cat > .transcrever.py << 'PYTHON'
from faster_whisper import WhisperModel
from pathlib import Path
import json
import sys

MODEL_SIZE = sys.argv[1]
LANGUAGE = sys.argv[2]
INPUT_FILE = sys.argv[3]

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
base = audio.with_suffix("")

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

for arquivo in parte1.mp3 parte2.mp3 parte3.mp3 parte4.mp3
do
    if [ -f "$arquivo" ]; then
        python .transcrever.py \
            "$MODELO" \
            "$LINGUA" \
            "$arquivo"
    else
        echo "Ignorado: $arquivo não encontrado"
    fi
done

rm -f .transcrever.py

echo
echo "Processamento concluído."

