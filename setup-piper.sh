#!/bin/bash

# Garante que o script pare imediatamente se houver algum erro
set -e

echo "==============================================================="
echo "🚀 Iniciando Configuração do Piper TTS no Zorin OS (Ubuntu)"
echo "==============================================================="

# 1. Atualizar a lista de pacotes e instalar dependências do Ubuntu/Zorin
echo "📦 Instalando dependências do sistema via APT (solicitará sua senha sudo)..."
sudo apt update
sudo apt install -y python3-pip python3-venv wget tar coreutils build-essential

# 2. Garantir que estamos na pasta correta
PASTA_TRABALHO="$HOME/audiobook-libs"
mkdir -p "$PASTA_TRABALHO"
cd "$PASTA_TRABALHO"

# 3. Criar o Ambiente Virtual do Python (venv)
echo "🐍 Criando ambiente virtual Python isolado (venv)..."
if [ ! -d "venv" ]; then
    python3 -m venv venv
    echo "✅ Ambiente venv criado com sucesso."
else
    echo "ℹ️ Ambiente venv já detectado. Pulando criação."
fi

# 4. Instalar o Piper dentro do Ambiente Virtual
echo "📥 Atualizando o pip e instalando o Piper TTS..."
./venv/bin/pip install --upgrade pip
./venv/bin/pip install piper-tts

# 5. Criar o atalho local para execução direta
echo "🔗 Criando atalho local para o executável do Piper..."
ln -sf "$PASTA_TRABALHO/venv/bin/piper" "$PASTA_TRABALHO/piper"

# 6. Baixar o modelo de voz em Português se não estiver presente
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
echo "🎉 AMBIENTE CONFIGURADO COM SUCESSO NO ZORIN OS!"
echo "==============================================================="
echo "O Piper e suas dependências em Python estão prontos."
echo "Um atalho foi gerado em: $PASTA_TRABALHO/piper"
echo ""
echo "Para fazer um teste rápido de voz, execute:"
echo "echo 'Ambiente configurado com sucesso.' | ./piper --model $MODELO --output_file teste.wav"
echo "==============================================================="

