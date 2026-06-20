#!/usr/bin/env bash

set -e

echo "======================================="
echo " Setup do ambiente de transcrição"
echo "======================================="

if command -v dnf >/dev/null 2>&1; then
    echo "Detectado Fedora/RHEL com dnf."
    sudo dnf install -y \
        ffmpeg \
        python3 \
        python3-pip \
        python3-virtualenv
elif command -v apt-get >/dev/null 2>&1; then
    echo "Detectado Debian/Ubuntu com apt-get."
    sudo apt-get update
    sudo apt-get install -y \
        ffmpeg \
        python3 \
        python3-venv \
        python3-pip
else
    echo "Gerenciador de pacotes não suportado neste sistema."
    echo "Instale manualmente ffmpeg, python3, python3-pip e python3-venv antes de continuar."
    exit 1
fi

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
