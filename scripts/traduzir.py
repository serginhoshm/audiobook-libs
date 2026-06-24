#!/usr/bin/env python3

import argparse
import re
import sys
from pathlib import Path

from deep_translator import GoogleTranslator
from tqdm import tqdm


def parse_args():
    parser = argparse.ArgumentParser(
        description="Traduz um arquivo SRT para português brasileiro."
    )
    parser.add_argument("input_srt", type=Path, help="Arquivo SRT de entrada.")
    parser.add_argument("output_srt", type=Path, help="Arquivo SRT de saída traduzido.")
    parser.add_argument(
        "source_lang",
        nargs="?",
        default="auto",
        help="Idioma de origem (ex: es, zh-CN, auto).",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    input_path = args.input_srt
    output_path = args.output_srt

    source_lang = (args.source_lang or "").strip()
    source_lang_key = source_lang.lower()
    if source_lang_key not in {"es", "zh-cn"}:
        print("Erro: idioma de origem inválido. Use apenas 'es' ou 'zh-CN'.")
        sys.exit(1)

    source_lang_normalized = "es" if source_lang_key == "es" else "zh-CN"

    if not input_path.exists():
        print(f"Erro: arquivo de entrada não encontrado: {input_path}")
        sys.exit(1)

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with open(input_path, "r", encoding="utf-8") as f:
        linhas = f.readlines()

    tradutor = GoogleTranslator(source=source_lang_normalized, target="pt")
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
