#!/usr/bin/env python3
import re
import sys
from pathlib import Path


def extrair_texto_srt(arquivo_entrada, arquivo_saida, arquivo_capitulos=None):
    try:
        with open(arquivo_entrada, 'r', encoding='utf-8') as f:
            conteudo = f.read()
    except FileNotFoundError:
        print(f"Erro: Arquivo '{arquivo_entrada}' não encontrado.")
        sys.exit(1)

    blocos = re.split(r'\n\s*\n', conteudo.strip())
    linhas_limpas = []

    for bloco in blocos:
        linhas = [l.strip() for l in bloco.split('\n') if l.strip()]
        if len(linhas) >= 3:
            texto_legenda = " ".join(linhas[2:])
            if texto_legenda:
                if not texto_legenda.endswith(('.', '!', '?', '...', ',', ':')):
                    texto_legenda += "."
                linhas_limpas.append(texto_legenda)

    if not linhas_limpas:
        print(f"⚠️ Nenhum texto foi encontrado em '{arquivo_entrada}'.")
        return

    arquivo_saida.parent.mkdir(parents=True, exist_ok=True)
    with open(arquivo_saida, 'w', encoding='utf-8') as f:
        f.write("\n".join(linhas_limpas) + "\n")
    print(f"✅ Texto limpo extraído para '{arquivo_saida}' ({len(linhas_limpas)} frases)")

    if arquivo_capitulos:
        arquivo_capitulos.parent.mkdir(parents=True, exist_ok=True)
        with open(arquivo_capitulos, 'w', encoding='utf-8') as f:
            f.write("\n\n".join(linhas_limpas) + "\n")
        print(f"✅ Texto estruturado com pausas em '{arquivo_capitulos}'")


if __name__ == "__main__":
    ROOT = Path(__file__).resolve().parents[1]
    candidatos = [
        ROOT / "data" / "outputs" / "audio_entrada.pt.srt",
        ROOT / "data" / "outputs" / "audio_entrada.srt",
        ROOT / "data" / "outputs" / "output.srt",
    ]
    INPUT = next((c for c in candidatos if c.exists()), None)

    if INPUT is None:
        print("Erro: nenhum arquivo SRT encontrado em data/outputs.")
        print("Esperado um destes arquivos: audio_entrada.pt.srt, audio_entrada.srt ou output.srt.")
        sys.exit(1)

    OUTPUT = ROOT / "data" / "inputs" / "livro.txt"
    CAPITULOS = ROOT / "data" / "inputs" / "livro_capitulos.txt"
    extrair_texto_srt(INPUT, OUTPUT, CAPITULOS)