#!/usr/bin/env bash

set -e

echo "==============================================================="
echo "🚀 Iniciando configuração do Piper TTS"
echo "==============================================================="

if command -v dnf >/dev/null 2>&1; then
    echo "📦 Instalando dependências do sistema com dnf..."
    sudo dnf install -y \
        python3-pip \
        python3-virtualenv \
        wget \
        tar \
        coreutils \
        gcc-c++
elif command -v apt-get >/dev/null 2>&1; then
    echo "📦 Instalando dependências do sistema com apt-get..."
    sudo apt-get update
    sudo apt-get install -y \
        python3-pip \
        python3-venv \
        wget \
        tar \
        coreutils \
        build-essential
else
    echo "Gerenciador de pacotes não suportado neste sistema."
    echo "Instale manualmente python3-pip, python3-venv, wget, tar, coreutils e build tools."
    exit 1
fi

PASTA_TRABALHO="$HOME/audiobook-libs"
mkdir -p "$PASTA_TRABALHO"
cd "$PASTA_TRABALHO"

echo "🐍 Criando ambiente virtual Python isolado..."
if [ ! -d ".venv" ]; then
    python3 -m venv .venv
    echo "✅ Ambiente .venv criado com sucesso."
else
    echo "ℹ️ Ambiente .venv já detectado. Pulando criação."
fi

echo "📥 Atualizando o pip e instalando o Piper TTS..."
./.venv/bin/pip install --upgrade pip
./.venv/bin/pip install piper-tts

echo "🔗 Criando atalho local para o executável do Piper..."
ln -sf "$PASTA_TRABALHO/.venv/bin/piper" "$PASTA_TRABALHO/piper"

MODELO="pt_BR-faber-medium.onnx"
CONFIG_MODELO="pt_BR-faber-medium.onnx.json"

echo "🎙️ Verificando modelo de voz em português ($MODELO)..."
if [ ! -f "$MODELO" ]; then
    echo "📥 Baixando modelo de voz (Faber Medium)..."
    wget -c "https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/faber/medium/$MODELO"
else
    echo "✅ Modelo de voz já existe localmente."
fi

if [ ! -f "$CONFIG_MODELO" ]; then
    echo "📥 Baixando arquivo de configuração do modelo..."
    wget -c "https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/faber/medium/$CONFIG_MODELO"
else
    echo "✅ Arquivo de configuração já existe localmente."
fi

echo "==============================================================="
echo "🎉 AMBIENTE CONFIGURADO COM SUCESSO"
echo "==============================================================="
echo "O Piper e suas dependências em Python estão prontos."
echo "Um atalho foi gerado em: $PASTA_TRABALHO/piper"
echo ""
echo "Para fazer um teste rápido de voz, execute:"
echo "echo 'Ambiente configurado com sucesso.' | ./piper --model $MODELO --output_file teste.wav"
echo "==============================================================="

