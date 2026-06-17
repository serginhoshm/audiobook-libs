#!/usr/bin/env python3
import os
import subprocess
from pydub import AudioSegment
import pysrt

# Configurações
ARQUIVO_SRT = "output.srt"
MODELO_VOZ = "pt_BR-jeff-medium.onnx"
AUDIO_FINAL = "audiobook_sincronizado.wav"

print("🎬 Lendo arquivo de legendas SRT...")
legendas = pysrt.open(ARQUIVO_SRT, encoding='utf-8')

# Inicializa um áudio completamente silencioso
audio_consolidado = AudioSegment.empty()
tempo_atual_ms = 0

print("🎙️ Iniciando síntese sincronizada por timestamp...")

for i, legenda in enumerate(legendas):
    # Converte os tempos do SRT para milissegundos
    inicio_ms = (legenda.start.hours * 3600000 + legenda.start.minutes * 60000 + 
                 legenda.start.seconds * 1000 + legenda.start.milliseconds)
    
    fim_ms = (legenda.end.hours * 3600000 + legenda.end.minutes * 60000 + 
               legenda.end.seconds * 1000 + legenda.end.milliseconds)
    
    texto = legenda.text.replace('\n', ' ')
    
    # 1. Preenche o vácuo/silêncio antes da fala começar
    if inicio_ms > tempo_atual_ms:
        silencio_necessario = inicio_ms - tempo_atual_ms
        audio_consolidado += AudioSegment.silent(duration=silencio_necessario)
        tempo_atual_ms = inicio_ms

    # 2. Gera o áudio temporário da frase com o Piper
    temp_wav = f"temp_{i}.wav"
    cmd = f"echo '{texto}' | ./piper --model {MODELO_VOZ} --output_file {temp_wav}"
    subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    
    if os.path.exists(temp_wav):
        audio_frase = AudioSegment.from_wav(temp_wav)
        duracao_frase_ms = len(audio_frase)
        duracao_limite_ms = fim_ms - inicio_ms
        
        # Ajuste de velocidade se a IA falar mais devagar do que o tempo da legenda permite
        if duracao_frase_ms > duracao_limite_ms and duracao_limite_ms > 0:
            # Força o áudio a caber no tempo exato acelerando-o levemente
            taxa_velocidade = duracao_frase_ms / duracao_limite_ms
            # Nota: Pydub não altera velocidade nativamente sem mudar tom, 
            # mas truncar ou manter o tempo original evita desalinhamento nas próximas falas.
            audio_frase = audio_frase[:duracao_limite_ms]
        
        # Adiciona a fala ao arquivo consolidado
        audio_consolidado += audio_frase
        tempo_atual_ms += len(audio_frase)
        
        # Limpa o arquivo temporário
        os.remove(temp_wav)

    if i % 100 == 0:
        print(f"📦 Processadas {i}/{len(legendas)} legendas...")

# Salva o arquivo final que terá exatamente a mesma linha do tempo do vídeo
audio_consolidado.export(AUDIO_FINAL, format="wav")
print(f"🎉 Sucesso! Áudio sincronizado gerado em: {AUDIO_FINAL}")