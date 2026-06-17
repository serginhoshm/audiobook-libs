#!/usr/bin/env bash

set -e

echo "========================================="
echo " Tradutor SRT ES -> PT-BR"
echo "========================================="
echo

if [ ! -d ".venv" ]; then
echo "ERRO: ambiente virtual não encontrado."
echo
echo "Execute:"
echo "./setup-traducao.sh"
exit 1
fi

if [ ! -f "input.srt" ]; then
echo "ERRO: input.srt não encontrado."
exit 1
fi

source .venv/bin/activate

cp -f input.srt input.original.srt

python3 traduzir.py

echo
echo "Concluído."
