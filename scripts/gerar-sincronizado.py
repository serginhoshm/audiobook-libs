#!/usr/bin/env python3
import argparse
import logging
import os
import re
import shutil
import subprocess
import sys
import wave
from pathlib import Path
import pysrt
from tqdm import tqdm

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--srt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--piper", type=Path, required=True)
    parser.add_argument("--pause_duration", type=float, default=0.0)
    parser.add_argument("--source_lang", type=str, default="auto")
    parser.add_argument("--zh_gap_scale", type=float, default=0.85)
    parser.add_argument("--zh_pause_scale", type=float, default=0.5)
    parser.add_argument("--zh_length_scale", type=float, default=0.88)
    parser.add_argument("--normalize_drift_threshold", type=float, default=0.02)
    parser.add_argument("--piper-cuda", action="store_true", help="Executa Piper com --cuda")
    return parser.parse_args()

def ms_to_bytes(ms, params):
    # Garante que o número de bytes seja par (importante para 16-bit)
    num_bytes = int((params.nchannels * params.sampwidth * params.framerate * ms) / 1000)
    return num_bytes - (num_bytes % (params.nchannels * params.sampwidth))


def to_ms(ts):
    return ts.hours * 3600000 + ts.minutes * 60000 + ts.seconds * 1000 + ts.milliseconds


def sanitize_tts_text(text):
    cleaned = re.sub(r"[\x00-\x1f\x7f]", " ", text or "")
    cleaned = cleaned.replace("\u201c", '"').replace("\u201d", '"').replace("\u2019", "'")
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned


def run_piper(piper_bin, model_path, output_wav, text):
    return subprocess.run(
        [str(piper_bin), "--model", str(model_path), "--output_file", str(output_wav)],
        input=text,
        text=True,
        capture_output=True,
        check=False,
    )


def build_atempo_chain(factor):
    # ffmpeg atempo accepts values in [0.5, 2.0]; split if needed.
    parts = []
    remaining = float(factor)

    while remaining > 2.0:
        parts.append("atempo=2.0")
        remaining /= 2.0

    while remaining < 0.5:
        parts.append("atempo=0.5")
        remaining /= 0.5

    parts.append(f"atempo={remaining:.6f}")
    return ",".join(parts)


def normalize_output_duration_with_ffmpeg(output_wav, target_ms, current_ms, threshold):
    if target_ms <= 0 or current_ms <= 0:
        return current_ms

    ratio = current_ms / target_ms
    drift = abs(ratio - 1.0)
    if drift <= threshold:
        return current_ms

    if not shutil.which("ffmpeg"):
        logging.warning(
            "ffmpeg indisponivel; nao foi possivel normalizar duracao (ratio=%.4f)",
            ratio,
        )
        return current_ms

    speed_factor = ratio
    atempo_filter = build_atempo_chain(speed_factor)
    tmp_out = output_wav.with_suffix(".normalized.wav")

    logging.info(
        "Normalizando duracao final (ratio=%.4f, speed=%.4f, filter=%s)",
        ratio,
        speed_factor,
        atempo_filter,
    )

    proc = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(output_wav),
            "-filter:a",
            atempo_filter,
            str(tmp_out),
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    if proc.returncode != 0 or (not tmp_out.exists()):
        logging.warning(
            "Falha ao normalizar duracao com ffmpeg: %s",
            (proc.stderr or "").strip()[:300],
        )
        if tmp_out.exists():
            tmp_out.unlink(missing_ok=True)
        return current_ms

    os.replace(tmp_out, output_wav)
    return int(target_ms)

def main():
    args = parse_args()
    temp_wav = Path("temp_frase.wav")
    use_piper_cuda = bool(args.piper_cuda)

    source_lang_key = (args.source_lang or "auto").strip().lower()
    is_chinese = source_lang_key in {"zh", "zh-cn", "zh_cn"}
    gap_scale = args.zh_gap_scale if is_chinese else 1.0
    pause_scale = args.zh_pause_scale if is_chinese else 1.0
    length_scale = args.zh_length_scale if is_chinese else 1.0

    if not args.srt.exists():
        logging.error("SRT de entrada nao encontrado: %s", args.srt)
        return 1
    if not args.model.exists():
        logging.error("Modelo de voz nao encontrado: %s", args.model)
        return 1
    if not args.piper.exists():
        logging.error("Executavel do Piper nao encontrado: %s", args.piper)
        return 1
    
    try:
        legendas = pysrt.open(str(args.srt), encoding='utf-8')
    except Exception:
        legendas = pysrt.open(str(args.srt), encoding='iso-8859-1')

    if len(legendas) == 0:
        logging.error("SRT de entrada nao possui legendas: %s", args.srt)
        return 1
        
    audio_frames = []
    final_params = None
    current_clock_ms = 0 # O tempo exato onde o áudio "está"
    total_legendas = len(legendas)
    
    logging.info(f"Processando {total_legendas} entradas do SRT...")
    if use_piper_cuda:
        logging.info("Piper CUDA habilitado para esta execucao.")

    try:
        for i, leg in enumerate(
            tqdm(legendas, total=total_legendas, desc="[piper]", unit="legenda", leave=False, disable=not sys.stderr.isatty()),
            start=1,
        ):
            texto = leg.text.replace('\r', '').replace('\n', ' ').strip()
            if not texto:
                continue

            # Tempo de inicio desejado para esta fala.
            target_start_ms = to_ms(leg.start)
            target_end_ms = to_ms(leg.end)
            subtitle_duration_ms = max(0, target_end_ms - target_start_ms)

            synth_text = texto
            piper_cmd = [str(args.piper), "--model", str(args.model), "--output_file", str(temp_wav)]
            if use_piper_cuda:
                piper_cmd.append("--cuda")
            if is_chinese:
                piper_cmd.extend(["--length_scale", str(length_scale)])

            piper_result = subprocess.run(
                piper_cmd,
                input=synth_text,
                text=True,
                capture_output=True,
                check=False,
            )

            if piper_result.returncode != 0 and use_piper_cuda:
                logging.warning(
                    "[%s/%s] Piper com CUDA falhou; alternando para CPU para o restante da execucao. stderr=%s",
                    i + 1,
                    total_legendas,
                    (piper_result.stderr or "").strip()[:300],
                )
                use_piper_cuda = False
                piper_cmd = [str(args.piper), "--model", str(args.model), "--output_file", str(temp_wav)]
                if is_chinese:
                    piper_cmd.extend(["--length_scale", str(length_scale)])
                piper_result = subprocess.run(
                    piper_cmd,
                    input=synth_text,
                    text=True,
                    capture_output=True,
                    check=False,
                )

            if piper_result.returncode != 0 or (not temp_wav.exists()) or temp_wav.stat().st_size == 0:
                sanitized = sanitize_tts_text(texto)
                if sanitized and sanitized != texto:
                    logging.warning(
                        "[%s/%s] Piper falhou, tentando texto sanitizado.",
                        i + 1,
                        total_legendas,
                    )
                    piper_result = subprocess.run(
                        piper_cmd,
                        input=sanitized,
                        text=True,
                        capture_output=True,
                        check=False,
                    )

            if piper_result.returncode != 0 or (not temp_wav.exists()) or temp_wav.stat().st_size == 0:
                logging.error(
                    "[%s/%s] Piper falhou; inserindo silencio para manter sincronismo. stderr=%s",
                    i + 1,
                    total_legendas,
                    (piper_result.stderr or "").strip()[:300],
                )
                if final_params is not None:
                    if target_start_ms > current_clock_ms:
                        gap_ms = int((target_start_ms - current_clock_ms) * gap_scale)
                        audio_frames.append(b"\x00" * ms_to_bytes(gap_ms, final_params))
                        current_clock_ms += gap_ms

                    audio_frames.append(b"\x00" * ms_to_bytes(subtitle_duration_ms, final_params))
                    current_clock_ms += subtitle_duration_ms

                    if args.pause_duration > 0:
                        p_ms = int(args.pause_duration * 1000 * pause_scale)
                        audio_frames.append(b"\x00" * ms_to_bytes(p_ms, final_params))
                        current_clock_ms += p_ms
                else:
                    logging.warning(
                        "[%s/%s] Primeira sintese falhou e parametros de audio ainda indisponiveis; legenda ignorada.",
                        i + 1,
                        total_legendas,
                    )

                if temp_wav.exists():
                    os.remove(temp_wav)
                continue

            with wave.open(str(temp_wav), "rb") as wav:
                params = wav.getparams()
                frames = wav.readframes(wav.getnframes())
                if final_params is None:
                    final_params = params

                if target_start_ms > current_clock_ms:
                    gap_ms = int((target_start_ms - current_clock_ms) * gap_scale)
                    audio_frames.append(b"\x00" * ms_to_bytes(gap_ms, final_params))
                    current_clock_ms += gap_ms

                audio_frames.append(frames)

                duracao_fala_ms = (len(frames) / (params.nchannels * params.sampwidth * params.framerate)) * 1000
                current_clock_ms += duracao_fala_ms

                if args.pause_duration > 0:
                    p_ms = int(args.pause_duration * 1000 * pause_scale)
                    audio_frames.append(b"\x00" * ms_to_bytes(p_ms, final_params))
                    current_clock_ms += p_ms

            if temp_wav.exists():
                os.remove(temp_wav)

        if final_params is None:
            logging.error("Nenhum audio util foi gerado a partir do SRT: %s", args.srt)
            return 1

        target_end_ms = to_ms(legendas[-1].end)

        if target_end_ms > current_clock_ms:
            gap_ms = int((target_end_ms - current_clock_ms) * gap_scale)
            audio_frames.append(b"\x00" * ms_to_bytes(gap_ms, final_params))
            current_clock_ms += gap_ms

        args.output.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(args.output), "wb") as out:
            out.setparams(final_params)
            for frame in audio_frames:
                out.writeframes(frame)

        current_clock_ms = normalize_output_duration_with_ffmpeg(
            args.output,
            target_end_ms,
            current_clock_ms,
            max(0.0, float(args.normalize_drift_threshold)),
        )
    finally:
        if temp_wav.exists():
            os.remove(temp_wav)

    logging.info(f"✅ Finalizado. Duração calculada: {current_clock_ms/1000:.2f}s")
    return 0

if __name__ == "__main__":
    sys.exit(main())
