#!/usr/bin/env python3
import re
import sys

def extrair_texto_srt(arquivo_entrada, arquivo_saida, arquivo_capitulos=None):
    try:
        with open(arquivo_entrada, 'r', encoding='utf-8') as f:
            conteudo = f.read()
    except FileNotFoundError:
        print(f"Erro: Arquivo '{arquivo_entrada}' não encontrado.")
        sys.exit(1)

    # Divide os blocos da legenda
    blocos = re.split(r'\n\s*\n', conteudo.strip())
    
    linhas_limpas = []
    
    for bloco in blocos:
        linhas = [l.strip() for l in bloco.split('\n') if l.strip()]
        if len(linhas) >= 3:
            texto_legenda = " ".join(linhas[2:])
            if texto_legenda:
                # Se a frase não terminar com pontuação, adiciona um ponto final
                # para forçar o Piper a reconhecer o fim da sentença
                if not texto_legenda.endswith(('.', '!', '?', '...', ',', ':')):
                    texto_legenda += "."
                linhas_limpas.append(texto_legenda)

    # Salva o livro.txt tradicional
    with open(arquivo_saida, 'w', encoding='utf-8') as f:
        f.write("\n".join(linhas_limpas) + "\n")
    print(f"✅ Texto limpo extraído para '{arquivo_saida}'")

    # Para o livro_capitulos.txt, vamos colocar uma quebra de linha extra (linha em branco)
    # entre cada frase. Isso ajuda visualmente e na leitura do Piper.
    if arquivo_capitulos:
        with open(arquivo_capitulos, 'w', encoding='utf-8') as f:
            f.write("\n\n".join(linhas_limpas) + "\n")
        print(f"✅ Texto estruturado com pausas em '{arquivo_capitulos}'")

if __name__ == "__main__":
    extrair_texto_srt("output.srt", "livro.txt", "livro_capitulos.txt")