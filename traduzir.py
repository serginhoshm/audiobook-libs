#!/usr/bin/env python3

import re
from deep_translator import GoogleTranslator
from tqdm import tqdm

with open("input.srt", "r", encoding="utf-8") as f:
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

with open("output.srt", "w", encoding="utf-8") as f:
    f.writelines(resultado)

print("Concluído.")