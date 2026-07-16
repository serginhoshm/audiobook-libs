#!/usr/bin/env python3

import argparse
import logging
import os
import sys
import traceback
from pathlib import Path

from faster_whisper import WhisperModel


logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stdout)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate transcription and SRT files from audio."
    )
    parser.add_argument("input_audio", type=Path, help="Input audio file.")
    parser.add_argument("output_dir", type=Path, help="Output directory for generated files.")
    parser.add_argument("language", type=str, help="Language code (for example: es, zh) or auto.")
    parser.add_argument("model_size", type=str, help="Whisper model size (for example: tiny, base).")
    parser.add_argument("output_base", type=str, help="Base filename for generated outputs.")
    return parser.parse_args()


def srt_time(sec):
    h = int(sec // 3600)
    m = int((sec % 3600) // 60)
    s = int(sec % 60)
    ms = int((sec - int(sec)) * 1000)
    return f"{h:02}:{m:02}:{s:02},{ms:03}"


def _load_model(model_dir: Path) -> WhisperModel:
    model = WhisperModel(
        str(model_dir),
        device="cpu",
        compute_type="int8",
        local_files_only=True,
    )
    return model


def _collect_segments(model: WhisperModel, audio: Path, language: str):
    transcribe_kwargs = {
        "beam_size": 5,
        "vad_filter": True,
    }
    if language != "auto":
        transcribe_kwargs["language"] = language

    segments_iter, info = model.transcribe(str(audio), **transcribe_kwargs)
    duration = getattr(info, "duration", None)
    if duration:
        logging.info(f"[whisper] Starting transcription for {audio.name} ({duration:.1f}s)")
    else:
        logging.info(f"[whisper] Starting transcription for {audio.name}")

    collected_segments = []
    emitted_bucket = -1
    for seg in segments_iter:
        collected_segments.append(seg)
        if not duration or duration <= 0:
            continue

        percent = max(0, min(100, int((seg.end / duration) * 100)))
        bucket = 100 if percent >= 100 else (percent // 5) * 5
        if bucket > emitted_bucket:
            emitted_bucket = bucket
            logging.info(f"[whisper] progress={bucket}%")

    if duration and duration > 0 and emitted_bucket < 100:
        logging.info("[whisper] progress=100%")

    return collected_segments


def _write_srt(artifact_srt: Path, segments) -> None:
    with open(artifact_srt, "w", encoding="utf-8") as f:
        for n, seg in enumerate(segments, start=1):
            f.write(f"{n}\n")
            f.write(f"{srt_time(seg.start)} --> {srt_time(seg.end)}\n")
            f.write(seg.text.strip() + "\n\n")


def main():
    args = parse_args()

    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    audio = args.input_audio
    output_base = Path(args.output_base).name
    artifact_srt = output_dir / f"{output_base}.srt"

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
                f"Error: local Whisper model not found at {model_dir}. "
                "Run setup/install_all.sh to prepare local artifacts."
            ),
            flush=True,
        )
        sys.exit(1)

    language = (args.language or "").strip().lower()
    if language not in {"es", "zh", "auto"}:
        print("Error: invalid language. Use only 'es', 'zh', or 'auto'.", flush=True)
        sys.exit(1)

    try:
        model = _load_model(model_dir)
        logging.info(
            f"[whisper] Model loaded: {args.model_size} | device=cpu | compute_type=int8"
        )

        segments = _collect_segments(model, audio, language)
        logging.info(f"[whisper] Transcription completed with {len(segments)} segments")
        _write_srt(artifact_srt, segments)
        print(f"Completed: {audio.name}", flush=True)
        return
    except Exception as exc:
        logging.error("[whisper] Transcription failed: %s", exc)
        traceback.print_exc()
        sys.exit(2)


if __name__ == "__main__":
    main()
