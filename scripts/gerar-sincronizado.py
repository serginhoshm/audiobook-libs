#!/usr/bin/env python3
import argparse
import logging
import os
import subprocess
import sys
import wave
from pathlib import Path
import pysrt

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
    return parser.parse_args()

def ms_to_bytes(ms, params):
    # Garante que o número de bytes seja par (importante para 16-bit)
    num_bytes = int((params.nchannels * params.sampwidth * params.framerate * ms) / 1000)
    return num_bytes - (num_bytes % (params.nchannels * params.sampwidth))

def main():
    args = parse_args()
    temp_wav = Path("temp_frase.wav")

    source_lang_key = (args.source_lang or "auto").strip().lower()
    is_chinese = source_lang_key in {"zh", "zh-cn", "zh_cn"}
    gap_scale = args.zh_gap_scale if is_chinese else 1.0
    pause_scale = args.zh_pause_scale if is_chinese else 1.0

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

    try:
        for i, leg in enumerate(legendas):
            texto = leg.text.replace('\r', '').replace('\n', ' ').strip()
            if not texto:
                continue

            logging.info("[%s/%s] Gerando audio para legenda em %02d:%02d:%02d,%03d",
                         i + 1,
                         total_legendas,
                         leg.start.hours,
                         leg.start.minutes,
                         leg.start.seconds,
                         leg.start.milliseconds)

            # Tempo de inicio desejado para esta fala.
            target_start_ms = (leg.start.hours * 3600000 + leg.start.minutes * 60000 +
                               leg.start.seconds * 1000 + leg.start.milliseconds)

            subprocess.run(
                [str(args.piper), "--model", str(args.model), "--output_file", str(temp_wav)],
                input=texto, text=True, check=True
            )

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

            logging.info("[%s/%s] Audio acumulado: %.2fs", i + 1, total_legendas, current_clock_ms / 1000)

            if temp_wav.exists():
                os.remove(temp_wav)

        if final_params is None:
            logging.error("Nenhum audio util foi gerado a partir do SRT: %s", args.srt)
            return 1

        target_end_ms = (legendas[-1].end.hours * 3600000 + legendas[-1].end.minutes * 60000 +
                         legendas[-1].end.seconds * 1000 + legendas[-1].end.milliseconds)

        if target_end_ms > current_clock_ms:
            gap_ms = int((target_end_ms - current_clock_ms) * gap_scale)
            audio_frames.append(b"\x00" * ms_to_bytes(gap_ms, final_params))
            current_clock_ms += gap_ms

        args.output.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(args.output), "wb") as out:
            out.setparams(final_params)
            for frame in audio_frames:
                out.writeframes(frame)
    finally:
        if temp_wav.exists():
            os.remove(temp_wav)

    logging.info(f"✅ Finalizado. Duração calculada: {current_clock_ms/1000:.2f}s")
    return 0

if __name__ == "__main__":
    sys.exit(main())
