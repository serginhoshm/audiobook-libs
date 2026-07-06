#!/usr/bin/env python3

import argparse
import logging
import os
import sys
from pathlib import Path

from faster_whisper import WhisperModel
from tqdm import tqdm


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
    parser.add_argument(
        "--device",
        type=str,
        choices=["cpu", "cuda"],
        default="cpu",
        help="faster-whisper device (cpu or cuda).",
    )
    return parser.parse_args()


def srt_time(sec):
    h = int(sec // 3600)
    m = int((sec % 3600) // 60)
    s = int(sec % 60)
    ms = int((sec - int(sec)) * 1000)
    return f"{h:02}:{m:02}:{s:02},{ms:03}"


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
                "[whisper] Failed to start on CUDA (%s). Falling back to CPU.",
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
        f"[whisper] Model loaded: {args.model_size} | device={selected_device} | compute_type={compute_type}"
    )

    language = (args.language or "").strip().lower()
    if language not in {"es", "zh", "auto"}:
        print("Error: invalid language. Use only 'es', 'zh', or 'auto'.", flush=True)
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
        logging.info(f"[whisper] Starting transcription for {audio.name} ({duration:.1f}s)")
    else:
        logging.info(f"[whisper] Starting transcription for {audio.name}")

    collected_segments = []
    for seg in tqdm(segments, desc="[whisper]", unit="seg", leave=False, disable=not sys.stderr.isatty()):
        collected_segments.append(seg)

    segments = collected_segments
    logging.info(f"[whisper] Transcription completed with {len(segments)} segments")

    with open(artifact_srt, "w", encoding="utf-8") as f:
        for n, seg in enumerate(segments, start=1):
            f.write(f"{n}\n")
            f.write(f"{srt_time(seg.start)} --> {srt_time(seg.end)}\n")
            f.write(seg.text.strip() + "\n\n")

    print(f"Completed: {audio.name}", flush=True)


if __name__ == "__main__":
    main()
