#!/usr/bin/env python3

import argparse
import json
import logging
import os
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
    parser.add_argument("language", type=str, help="Código do idioma (ex: es, zh) ou auto.")
    parser.add_argument("model_size", type=str, help="Tamanho do modelo Whisper (ex: tiny, base).")
    parser.add_argument("output_base", type=str, help="Nome base para os arquivos gerados.")
    parser.add_argument(
        "--device",
        type=str,
        choices=["cpu", "cuda"],
        default="cpu",
        help="Device do faster-whisper (cpu ou cuda).",
    )
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
    output_base = Path(args.output_base).name
    base = output_dir / output_base
    artifact_txt = output_dir / f"{output_base}.txt"
    artifact_srt = output_dir / f"{output_base}.srt"
    artifact_vtt = output_dir / f"{output_base}.vtt"
    artifact_tsv = output_dir / f"{output_base}.tsv"
    artifact_json = output_dir / f"{output_base}.json"

    project_root = Path(__file__).resolve().parents[1]
    models_root = Path(
        os.environ.get(
            "WHISPER_MODELS_DIR",
            str(project_root / "models" / "faster-whisper"),
        )
    )
    model_dir = models_root / args.model_size
    if not model_dir.is_dir():
        print(
            (
                f"Erro: modelo Whisper local não encontrado em {model_dir}. "
                "Execute setup/install_all.sh para preparar os artefatos."
            ),
            flush=True,
        )
        sys.exit(1)

    selected_device = args.device
    compute_type = "float16" if selected_device == "cuda" else "int8"

    try:
        model = WhisperModel(
            str(model_dir),
            device=selected_device,
            compute_type=compute_type,
            local_files_only=True,
        )
    except Exception as exc:
        if selected_device == "cuda":
            logging.warning(
                "[whisper] Falha ao iniciar em CUDA (%s). Recuando para CPU.",
                exc,
            )
            selected_device = "cpu"
            compute_type = "int8"
            model = WhisperModel(
                str(model_dir),
                device=selected_device,
                compute_type=compute_type,
                local_files_only=True,
            )
        else:
            raise

    logging.info(
        f"[whisper] Modelo carregado: {args.model_size} | device={selected_device} | compute_type={compute_type}"
    )

    language = (args.language or "").strip().lower()
    if language not in {"es", "zh", "auto"}:
        print("Erro: idioma inválido. Use apenas 'es', 'zh' ou 'auto'.", flush=True)
        sys.exit(1)

    transcribe_kwargs = {
        "beam_size": 5,
        "vad_filter": True,
    }
    if language != "auto":
        transcribe_kwargs["language"] = language

    segments, info = model.transcribe(str(audio), **transcribe_kwargs)

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

    with open(artifact_txt, "w", encoding="utf-8") as f:
        for seg in segments:
            f.write(seg.text.strip() + "\n")

    with open(artifact_srt, "w", encoding="utf-8") as f:
        for n, seg in enumerate(segments, start=1):
            f.write(f"{n}\n")
            f.write(f"{srt_time(seg.start)} --> {srt_time(seg.end)}\n")
            f.write(seg.text.strip() + "\n\n")

    with open(artifact_vtt, "w", encoding="utf-8") as f:
        f.write("WEBVTT\n\n")
        for seg in segments:
            f.write(f"{vtt_time(seg.start)} --> {vtt_time(seg.end)}\n")
            f.write(seg.text.strip() + "\n\n")

    with open(artifact_tsv, "w", encoding="utf-8") as f:
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
    if duration:
        data["audio_duration"] = duration
    if segments:
        data["transcription_end"] = segments[-1].end
    data["artifact_base"] = str(base)

    with open(artifact_json, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

    print(f"Concluido: {audio.name}", flush=True)


if __name__ == "__main__":
    main()
