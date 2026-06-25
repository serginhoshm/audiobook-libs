#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
import sys
import wave
from pathlib import Path


TIME_RE = re.compile(
    r"(\d{2}):(\d{2}):(\d{2}),(\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2}),(\d{3})"
)


def to_seconds(h, m, s, ms):
    return (int(h) * 3600) + (int(m) * 60) + int(s) + (int(ms) / 1000.0)


def read_srt_stats(srt_path: Path):
    if not srt_path.exists():
        return {
            "exists": False,
            "segments": 0,
            "start": 0.0,
            "end": 0.0,
            "duration": 0.0,
        }

    text = srt_path.read_text(encoding="utf-8", errors="replace")
    matches = TIME_RE.findall(text)
    if not matches:
        return {
            "exists": True,
            "segments": 0,
            "start": 0.0,
            "end": 0.0,
            "duration": 0.0,
        }

    starts = [to_seconds(*m[:4]) for m in matches]
    ends = [to_seconds(*m[4:]) for m in matches]
    start = min(starts)
    end = max(ends)
    return {
        "exists": True,
        "segments": len(matches),
        "start": start,
        "end": end,
        "duration": max(0.0, end - start),
    }


def media_duration_seconds(media_path: Path):
    if not media_path.exists():
        raise FileNotFoundError(f"Arquivo nao encontrado: {media_path}")

    ffprobe_cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(media_path),
    ]
    try:
        output = subprocess.check_output(ffprobe_cmd, stderr=subprocess.STDOUT, text=True)
        value = float(output.strip())
        if value > 0:
            return value
    except Exception:
        pass

    if media_path.suffix.lower() == ".wav":
        with wave.open(str(media_path), "rb") as wav:
            frames = wav.getnframes()
            rate = wav.getframerate()
            if rate <= 0:
                raise RuntimeError("WAV com framerate invalido")
            return frames / float(rate)

    raise RuntimeError(f"Nao foi possivel calcular duracao de: {media_path}")


def print_json(payload):
    print(json.dumps(payload, ensure_ascii=False))


def cmd_srt_stats(args):
    stats = read_srt_stats(args.srt)
    print_json(stats)
    return 0


def cmd_media_duration(args):
    try:
        duration = media_duration_seconds(args.input)
    except Exception as exc:
        print(f"ERRO: {exc}")
        return 1
    print(f"{duration:.3f}")
    return 0


def cmd_validate_transcription(args):
    stats = read_srt_stats(args.srt)
    if not stats["exists"]:
        print("INVALID: SRT inexistente")
        return 1
    if stats["segments"] < args.min_segments:
        print(f"INVALID: segmentos insuficientes ({stats['segments']})")
        return 1

    try:
        audio_duration = media_duration_seconds(args.audio)
    except Exception as exc:
        print(f"INVALID: duracao de audio indisponivel ({exc})")
        return 1

    if stats["end"] > audio_duration + args.tolerance:
        print(
            "INVALID: fim da transcricao ultrapassa o audio "
            f"(audio={audio_duration:.3f}s, srt_end={stats['end']:.3f}s, tolerance={args.tolerance:.3f}s)"
        )
        return 1

    coverage = 0.0
    if audio_duration > 0:
        coverage = stats["end"] / audio_duration
    if coverage < args.min_coverage:
        print(
            "INVALID: cobertura da transcricao abaixo do minimo "
            f"(coverage={coverage:.3f}, min_coverage={args.min_coverage:.3f}, "
            f"audio={audio_duration:.3f}s, srt_end={stats['end']:.3f}s)"
        )
        return 1

    print(
        "VALID: "
        f"segments={stats['segments']} audio={audio_duration:.3f}s srt_end={stats['end']:.3f}s "
        f"coverage={coverage:.3f}"
    )
    return 0


def cmd_validate_translation(args):
    source = read_srt_stats(args.source_srt)
    target = read_srt_stats(args.target_srt)

    if not source["exists"] or source["segments"] < args.min_segments:
        print("INVALID: SRT de origem invalido")
        return 1
    if not target["exists"] or target["segments"] < args.min_segments:
        print("INVALID: SRT traduzido invalido")
        return 1

    delta = abs(source["end"] - target["end"])
    if delta > args.tolerance:
        print(
            "INVALID: SRT traduzido com timeline divergente "
            f"(source_end={source['end']:.3f}s, target_end={target['end']:.3f}s, delta={delta:.3f}s)"
        )
        return 1

    print(
        "VALID: "
        f"source_segments={source['segments']} target_segments={target['segments']} delta={delta:.3f}s"
    )
    return 0


def cmd_validate_generated_audio(args):
    stats = read_srt_stats(args.srt)
    if not stats["exists"] or stats["segments"] < args.min_segments:
        print("INVALID: SRT de referencia invalido")
        return 1

    try:
        audio_duration = media_duration_seconds(args.audio)
    except Exception as exc:
        print(f"INVALID: audio final invalido ({exc})")
        return 1

    if audio_duration + args.tolerance < stats["end"]:
        print(
            "INVALID: audio final menor que timeline do SRT "
            f"(audio={audio_duration:.3f}s, srt_end={stats['end']:.3f}s)"
        )
        return 1

    print(
        "VALID: "
        f"audio={audio_duration:.3f}s srt_end={stats['end']:.3f}s segments={stats['segments']}"
    )
    return 0


def build_parser():
    parser = argparse.ArgumentParser(description="Validadores do pipeline de audiobook")
    sub = parser.add_subparsers(dest="command", required=True)

    p_srt = sub.add_parser("srt-stats")
    p_srt.add_argument("--srt", type=Path, required=True)
    p_srt.set_defaults(func=cmd_srt_stats)

    p_dur = sub.add_parser("media-duration")
    p_dur.add_argument("--input", type=Path, required=True)
    p_dur.set_defaults(func=cmd_media_duration)

    p_trans = sub.add_parser("validate-transcription")
    p_trans.add_argument("--audio", type=Path, required=True)
    p_trans.add_argument("--srt", type=Path, required=True)
    p_trans.add_argument("--tolerance", type=float, default=5.0)
    p_trans.add_argument("--min-coverage", type=float, default=0.85)
    p_trans.add_argument("--min-segments", type=int, default=1)
    p_trans.set_defaults(func=cmd_validate_transcription)

    p_trad = sub.add_parser("validate-translation")
    p_trad.add_argument("--source-srt", type=Path, required=True)
    p_trad.add_argument("--target-srt", type=Path, required=True)
    p_trad.add_argument("--tolerance", type=float, default=0.5)
    p_trad.add_argument("--min-segments", type=int, default=1)
    p_trad.set_defaults(func=cmd_validate_translation)

    p_audio = sub.add_parser("validate-generated-audio")
    p_audio.add_argument("--srt", type=Path, required=True)
    p_audio.add_argument("--audio", type=Path, required=True)
    p_audio.add_argument("--tolerance", type=float, default=1.5)
    p_audio.add_argument("--min-segments", type=int, default=1)
    p_audio.set_defaults(func=cmd_validate_generated_audio)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())