#!/usr/bin/env python3

import re
from pathlib import Path

from deep_translator import GoogleTranslator
from tqdm import tqdm

ROOT = Path(__file__).resolve().parents[1]
INPUT = ROOT / "data" / "inputs" / "input.srt"
OUTPUT = ROOT / "data" / "outputs" / "output.srt"

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