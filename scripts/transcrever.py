#!/usr/bin/env python3

import argparse
import json
import logging
import sys
from pathlib import Path

from faster_whisper import WhisperModel


logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stdout)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Gera arquivos de transcrição e SRT a partir de áudio." 
    )
    parser.add_argument("input_audio", type=Path, help="Arquivo de áudio de entrada.")
    parser.add_argument("output_dir", type=Path, help="Pasta de saída para os arquivos gerados.")
    parser.add_argument("language", type=str, help="Código do idioma (ex: es).")
    parser.add_argument("model_size", type=str, help="Tamanho do modelo Whisper (ex: tiny, base).")
    parser.add_argument("output_base", type=str, help="Nome base para os arquivos gerados.")
    return parser.parse_args()


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


def main():
    args = parse_args()

    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    audio = args.input_audio
    base = output_dir / args.output_base

    model = WhisperModel(
        args.model_size,
        device="cpu",
        compute_type="int8"
    )

    logging.info(f"[whisper] Modelo carregado: {args.model_size}")

    segments, info = model.transcribe(
        str(audio),
        language=args.language,
        beam_size=5,
        vad_filter=True
    )

    duration = getattr(info, "duration", None)
    if duration:
        logging.info(f"[whisper] Iniciando transcricao de {audio.name} ({duration:.1f}s)")
    else:
        logging.info(f"[whisper] Iniciando transcricao de {audio.name}")

    collected_segments = []
    for index, seg in enumerate(segments, start=1):
        collected_segments.append(seg)
        if duration and duration > 0:
            percent = min((seg.end / duration) * 100, 100)
            logging.info(
                f"[whisper] Segmento {index}: {seg.start:.1f}s -> {seg.end:.1f}s ({percent:.1f}%)"
            )
        else:
            logging.info(f"[whisper] Segmento {index}: {seg.start:.1f}s -> {seg.end:.1f}s")

    segments = collected_segments
    logging.info(f"[whisper] Transcricao concluida com {len(segments)} segmentos")

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
            f.write(f"{vtt_time(seg.start)} --> {vtt_time(seg.end)}\n")
            f.write(seg.text.strip() + "\n\n")

    with open(base.with_suffix(".tsv"), "w", encoding="utf-8") as f:
        f.write("start\tend\ttext\n")
        for seg in segments:
            texto = seg.text.replace("\n", " ")
            f.write(f"{seg.start:.3f}\t{seg.end:.3f}\t{texto}\n")

    data = {
        "language": info.language,
        "language_probability": info.language_probability,
        "segments": [
            {
                "start": seg.start,
                "end": seg.end,
                "text": seg.text.strip(),
            }
            for seg in segments
        ],
    }

    with open(base.with_suffix(".json"), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

    print(f"Concluido: {audio.name}", flush=True)


if __name__ == "__main__":
    main()
