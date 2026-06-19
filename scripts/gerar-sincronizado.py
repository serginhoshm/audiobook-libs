#!/usr/bin/env python3
import os
import subprocess
from pathlib import Path

from pydub import AudioSegment
import pysrt

ROOT = Path(__file__).resolve().parents[1]
ARQUIVO_SRT = ROOT / "data" / "outputs" / "output.srt"
AUDIO_FINAL = ROOT / "data" / "outputs" / "audiobook_sincronizado.wav"
MODELO_VOZ = ROOT / "data" / "models" / "pt_BR-jeff-medium.onnx"
PIPER = ROOT / "bin" / "piper"
TEMP_DIR = ROOT / "data" / "outputs" / "temp_audio"

TEMP_DIR.mkdir(parents=True, exist_ok=True)

print("🎬 Lendo arquivo de legendas SRT...")
legendas = pysrt.open(str(ARQUIVO_SRT), encoding='utf-8')

# Inicializa um áudio completamente silencioso
audio_consolidado = AudioSegment.empty()
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

    texto = legenda.text.replace('\n', ' ')

    if inicio_ms > tempo_atual_ms:
        silencio_necessario = inicio_ms - tempo_atual_ms
        audio_consolidado += AudioSegment.silent(duration=silencio_necessario)
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
        check=False,
    )

    if temp_wav.exists():
        audio_frase = AudioSegment.from_wav(str(temp_wav))
        duracao_frase_ms = len(audio_frase)
        duracao_limite_ms = fim_ms - inicio_ms

        if duracao_frase_ms > duracao_limite_ms and duracao_limite_ms > 0:
            audio_frase = audio_frase[:duracao_limite_ms]

        audio_consolidado += audio_frase
        tempo_atual_ms += len(audio_frase)
        os.remove(temp_wav)

    if i % 100 == 0:
        print(f"📦 Processadas {i}/{len(legendas)} legendas...")

AUDIO_FINAL.parent.mkdir(parents=True, exist_ok=True)
audio_consolidado.export(str(AUDIO_FINAL), format="wav")
print(f"🎉 Sucesso! Áudio sincronizado gerado em: {AUDIO_FINAL}")