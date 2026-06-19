#!/usr/bin/env bash

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "========================================="
echo " Tradutor SRT ES -> PT-BR"
echo "========================================="
echo

if [ ! -d ".venv" ]; then
    echo "ERRO: ambiente virtual não encontrado."
    echo
    echo "Execute:"
    echo "./setup/setup-traducao.sh"
    exit 1
fi

if [ ! -f "data/inputs/input.srt" ]; then
    echo "ERRO: data/inputs/input.srt não encontrado."
    exit 1
fi

source .venv/bin/activate

cp -f "data/inputs/input.srt" "data/inputs/input.original.srt"
python3 scripts/traduzir.py

echo
echo "Concluído."
