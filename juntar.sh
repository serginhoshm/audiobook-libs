#!/usr/bin/env python3

import re
from pathlib import Path

ARQUIVO_SAIDA = "input.srt"

arquivos = sorted(
    Path(".").glob("parte*.srt")
)

if not arquivos:
    print("Nenhum arquivo parte*.srt encontrado.")
    raise SystemExit(1)


def timestamp_para_ms(ts):
    h, m, resto = ts.split(":")
    s, ms = resto.split(",")

    return (
        int(h) * 3600000 +
        int(m) * 60000 +
        int(s) * 1000 +
        int(ms)
    )


def ms_para_timestamp(ms):

    horas = ms // 3600000
    ms %= 3600000

    minutos = ms // 60000
    ms %= 60000

    segundos = ms // 1000
    ms %= 1000

    return (
        f"{horas:02d}:"
        f"{minutos:02d}:"
        f"{segundos:02d},"
        f"{ms:03d}"
    )


def deslocar_timestamp(linha, offset):

    m = re.match(
        r'(\d\d:\d\d:\d\d,\d\d\d)\s-->\s(\d\d:\d\d:\d\d,\d\d\d)',
        linha
    )

    if not m:
        return linha

    inicio = timestamp_para_ms(m.group(1))
    fim = timestamp_para_ms(m.group(2))

    inicio += offset
    fim += offset

    return (
        f"{ms_para_timestamp(inicio)} --> "
        f"{ms_para_timestamp(fim)}"
    )


resultado = []
contador = 1
offset = 0

for arquivo in arquivos:

    print(f"Processando {arquivo.name}")

    with open(
        arquivo,
        "r",
        encoding="utf-8"
    ) as f:
        linhas = f.readlines()

    ultimo_fim = 0

    i = 0

    while i < len(linhas):

        linha = linhas[i].rstrip("\n")

        if re.match(r'^\d+$', linha):

            resultado.append(f"{contador}\n")
            contador += 1

            i += 1

            timestamp = linhas[i].rstrip("\n")

            resultado.append(
                deslocar_timestamp(
                    timestamp,
                    offset
                ) + "\n"
            )

            m = re.search(
                r'-->\s(\d\d:\d\d:\d\d,\d\d\d)',
                timestamp
            )

            if m:
                ultimo_fim = timestamp_para_ms(
                    m.group(1)
                )

            i += 1

            while (
                i < len(linhas)
                and linhas[i].strip()
            ):
                resultado.append(linhas[i])
                i += 1

            resultado.append("\n")

        i += 1

    offset += ultimo_fim

with open(
    ARQUIVO_SAIDA,
    "w",
    encoding="utf-8"
) as f:
    f.writelines(resultado)

print()
print(f"Gerado: {ARQUIVO_SAIDA}")
print(f"Legendas: {contador - 1}")
print(
    f"Duração total: "
    f"{offset/3600000:.2f} horas"
)
