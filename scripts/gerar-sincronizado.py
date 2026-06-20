#!/usr/bin/env python3
import argparse
import os
import subprocess
import sys
import wave
from pathlib import Path

import pysrt


def parse_args():
    parser = argparse.ArgumentParser(
        description="Gera áudio sincronizado a partir de um arquivo SRT usando Piper."
    )
    parser.add_argument(
        "--srt",
        type=Path,
        default=None,
        help="Caminho para o arquivo SRT. Se omitido, tenta localizar um arquivo padrão.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Caminho do arquivo WAV final. Se omitido, usa data/outputs/audio_entrada_sincronizado.wav.",
    )
    parser.add_argument(
        "--model",
        type=Path,
        default=None,
        help="Caminho para o modelo ONNX do Piper.",
    )
    parser.add_argument(
        "--piper",
        type=Path,
        default=None,
        help="Caminho para o executável do Piper.",
    )
    return parser.parse_args()


def abrir_wave(caminho):
    with wave.open(str(caminho), "rb") as wav:
        params = wav.getparams()
        frames = wav.readframes(wav.getnframes())
    return params, frames


def static_params_from_wave(wav_params):
    return (
        wav_params.nchannels,
        wav_params.sampwidth,
        wav_params.framerate,
        0,
        wav_params.comptype,
        wav_params.compname,
    )


def frames_para_silencio(params, duracao_ms):
    if duracao_ms <= 0:
        return b""
    bytes_por_segundo = params[0] * params[1] * params[2]
    return b"\x00" * int((bytes_por_segundo * duracao_ms) / 1000)


def concatenar_frames(frames_lista, params, destino):
    if not frames_lista:
        return

    with wave.open(str(destino), "wb") as wav:
        wav.setparams(params)
        for frames in frames_lista:
            wav.writeframes(frames)


def main():
    args = parse_args()
    ROOT = Path(__file__).resolve().parents[1]

    candidatos_srt = [
        ROOT / "data" / "outputs" / "audio_entrada.pt.srt",
        ROOT / "data" / "outputs" / "audio_entrada.srt",
        ROOT / "data" / "outputs" / "output.srt",
    ]
    ARQUIVO_SRT = args.srt if args.srt else next((c for c in candidatos_srt if c.exists()), None)

    if ARQUIVO_SRT is None:
        print("Erro: nenhum arquivo SRT encontrado em data/outputs.")
        print("Esperado um destes arquivos: audio_entrada.pt.srt, audio_entrada.srt ou output.srt.")
        return 1

    AUDIO_FINAL = args.output if args.output else ROOT / "data" / "outputs" / "audio_entrada_sincronizado.wav"
    MODELO_VOZ = args.model if args.model else ROOT / "data" / "models" / "pt_BR-jeff-medium.onnx"
    PIPER = args.piper if args.piper else ROOT / "bin" / "piper"
    TEMP_DIR = ROOT / "data" / "outputs" / "temp_audio"

    if not PIPER.exists():
        print(f"Erro: executável do Piper não encontrado em '{PIPER}'.")
        return 1
    if not MODELO_VOZ.exists():
        print(f"Erro: modelo do Piper não encontrado em '{MODELO_VOZ}'.")
        return 1

    TEMP_DIR.mkdir(parents=True, exist_ok=True)

    print(f"🎬 Lendo arquivo de legendas SRT: {ARQUIVO_SRT}")
    legendas = pysrt.open(str(ARQUIVO_SRT), encoding='utf-8')

    audio_frames = []
    params = None
    tempo_atual_ms = 0

    print("🎙️ Iniciando síntese sincronizada por timestamp...")

    for i, legenda in enumerate(legendas):
        inicio_ms = (
            legenda.start.hours * 3600000
            + legenda.start.minutes * 60000
            + legenda.start.seconds * 1000
            + legenda.start.milliseconds
        )

        fim_ms = (
            legenda.end.hours * 3600000
            + legenda.end.minutes * 60000
            + legenda.end.seconds * 1000
            + legenda.end.milliseconds
        )

        texto = legenda.text.replace('\n', ' ').strip()
        if not texto:
            continue

        if inicio_ms > tempo_atual_ms:
            silencio_necessario = inicio_ms - tempo_atual_ms
            if silencio_necessario > 0:
                if params is None:
                    params = (1, 2, 16000, 0, "NONE", "not compressed")
                audio_frames.append(frames_para_silencio(params, silencio_necessario))
                tempo_atual_ms = inicio_ms

        temp_wav = TEMP_DIR / f"temp_{i}.wav"
        subprocess.run(
            [
                str(PIPER),
                "--model",
                str(MODELO_VOZ),
                "--output_file",
                str(temp_wav),
            ],
            input=texto,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )

        if temp_wav.exists():
            frase_params, frase_frames = abrir_wave(temp_wav)
            frase_static_params = static_params_from_wave(frase_params)

            if params is None:
                params = frase_static_params
            elif frase_static_params[:3] != params[:3]:
                print(
                    f"⚠️  Configuração de áudio diferente para a legenda {i}: {frase_static_params} vs {params}."
                )

            duracao_limite_ms = max(0, fim_ms - inicio_ms)
            if duracao_limite_ms > 0:
                duracao_frase_ms = int(
                    (len(frase_frames) / (frase_static_params[1] * frase_static_params[0] * (frase_static_params[2] / 1000))) * 1000
                )
                if duracao_frase_ms > duracao_limite_ms:
                    frames_permitidos = int(
                        (duracao_limite_ms / 1000)
                        * frase_static_params[2]
                        * frase_static_params[1]
                        * frase_static_params[0]
                    )
                    frase_frames = frase_frames[:frames_permitidos]
                elif duracao_frase_ms < duracao_limite_ms:
                    frames_faltantes = int(
                        ((duracao_limite_ms - duracao_frase_ms) / 1000)
                        * frase_static_params[2]
                        * frase_static_params[1]
                        * frase_static_params[0]
                    )
                    frase_frames += b"\x00" * frames_faltantes

            audio_frames.append(frase_frames)
            tempo_atual_ms += int(
                (len(frase_frames) / (frase_static_params[1] * frase_static_params[0] * (frase_static_params[2] / 1000))) * 1000
            )
            os.remove(temp_wav)

        if i % 100 == 0:
            print(f"📦 Processadas {i}/{len(legendas)} legendas...")

    # garante que o áudio final respeite a duração total capturada no SRT
    if legendas and params is not None:
        ultimo_fim_ms = max(
            (
                legenda.end.hours * 3600000
                + legenda.end.minutes * 60000
                + legenda.end.seconds * 1000
                + legenda.end.milliseconds
            )
            for legenda in legendas
        )
        if tempo_atual_ms < ultimo_fim_ms:
            silencio_necessario = ultimo_fim_ms - tempo_atual_ms
            if silencio_necessario > 0:
                audio_frames.append(frames_para_silencio(params, silencio_necessario))

    if params is None:
        print("Erro: nenhum trecho de áudio foi gerado.")
        return 1

    concatenar_frames(audio_frames, params, AUDIO_FINAL)
    print(f"🎉 Sucesso! Áudio sincronizado gerado em: {AUDIO_FINAL}")
    return 0


if __name__ == "__main__":
    sys.exit(main())