#!/usr/bin/env bash

set -e

echo "======================================="
echo " Setup do ambiente de transcrição"
echo "======================================="

sudo apt update

sudo apt install -y \
    ffmpeg \
    python3 \
    python3-venv \
    python3-pip

if [ ! -d ".venv" ]; then
    echo
    echo "Criando ambiente virtual..."
    python3 -m venv .venv
fi

source .venv/bin/activate

echo
echo "Atualizando pip..."
python -m pip install --upgrade pip

echo
echo "Instalando Faster-Whisper..."
pip install faster-whisper

echo
echo "Testando instalação..."

python - << 'PYTHON'
from faster_whisper import WhisperModel
print("Faster-Whisper instalado com sucesso.")
PYTHON

echo
echo "======================================="
echo " Ambiente pronto."
echo "======================================="
echo
echo "Para usar:"
echo "source .venv/bin/activate"
