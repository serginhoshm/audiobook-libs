#!/usr/bin/env python3

import argparse
import re
import sys
from pathlib import Path

from deep_translator import GoogleTranslator
from tqdm import tqdm


def parse_args():
    parser = argparse.ArgumentParser(
        description="Traduz um arquivo SRT de espanhol para português brasileiro."
    )
    parser.add_argument("input_srt", type=Path, help="Arquivo SRT de entrada.")
    parser.add_argument("output_srt", type=Path, help="Arquivo SRT de saída traduzido.")
    return parser.parse_args()


def main():
    args = parse_args()
    input_path = args.input_srt
    output_path = args.output_srt

    if not input_path.exists():
        print(f"Erro: arquivo de entrada não encontrado: {input_path}")
        sys.exit(1)

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with open(input_path, "r", encoding="utf-8") as f:
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

    with open(output_path, "w", encoding="utf-8") as f:
        f.writelines(resultado)

    print(f"Concluído. Arquivo gerado em: {output_path}")


if __name__ == "__main__":
    main()
