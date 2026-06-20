#!/usr/bin/env python3

import re
import sys
from pathlib import Path

from deep_translator import GoogleTranslator
from tqdm import tqdm

ROOT = Path(__file__).resolve().parents[1]

INPUT_CANDIDATOS = [
    ROOT / "data" / "outputs" / "audio_entrada.srt",
    ROOT / "data" / "outputs" / "output.srt",
]

INPUT = next((caminho for caminho in INPUT_CANDIDATOS if caminho.exists()), None)
if INPUT is None:
    print("Erro: nenhum arquivo SRT encontrado em data/outputs.")
    print("Esperado: data/outputs/audio_entrada.srt (ou output.srt).")
    sys.exit(1)

OUTPUT = ROOT / "data" / "outputs" / "audio_entrada.pt.srt"

with open(INPUT, "r", encoding="utf-8") as f:
    linhas = f.readlines()

tradutor = GoogleTranslator(source="es", target="pt")
resultado = []

for linha in tqdm(linhas):
    texto = linha.rstrip("\n")

    if re.match(r"^\d+$", texto):
        resultado.append(linha)
        continue

    if "-->" in texto:
        resultado.append(linha)
        continue

    if texto.strip() == "":
        resultado.append(linha)
        continue

    try:
        traducao = tradutor.translate(texto)
        resultado.append(traducao + "\n")
    except Exception:
        resultado.append(linha)

OUTPUT.parent.mkdir(parents=True, exist_ok=True)
with open(OUTPUT, "w", encoding="utf-8") as f:
    f.writelines(resultado)

print(f"Concluído. Arquivo gerado em: {OUTPUT}")