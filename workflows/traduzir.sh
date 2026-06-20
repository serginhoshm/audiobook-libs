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

if [ ! -f "data/outputs/audio_entrada.srt" ] && [ ! -f "data/outputs/output.srt" ]; then
    echo "ERRO: nenhum arquivo SRT foi encontrado em data/outputs."
    echo "Execute primeiro a transcrição do áudio para gerar o arquivo de legenda."
    exit 1
fi

source .venv/bin/activate

python3 scripts/traduzir.py

echo
printf 'Arquivo traduzido gerado em: %s\n' "data/outputs/audio_entrada.pt.srt"
echo
printf 'Concluído.\n'
