#!/bin/bash

set -e

# Esperado pelo fluxo de geração de audiobook:
# - A entrada principal é o arquivo de legenda SRT em português brasileiro:
#   data/outputs/output.srt
# - O áudio final deve ser gerado em português (Brasil).
# - Cada fala do áudio deve respeitar os tempos definidos no SRT,
#   preservando a duração de cada trecho e o tempo total do arquivo.
# - O áudio produzido ao final deve ter duração total compatível com o
#   tempo acumulado do SRT, ou seja, o último timestamp do arquivo deve
#   coincidir com a duração final do áudio gerado.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"

# Arquivo SRT obrigatório para sincronização temporal do áudio final.
SRT_ENTRADA="$ROOT_DIR/data/outputs/output.srt"
PIPER_BIN="$ROOT_DIR/bin/piper"
MODELS_DIR="$ROOT_DIR/data/models"
OUTPUT_DIR="$ROOT_DIR/data/outputs"

DATA_ATUAL=$(date +%Y-%m-%d)

echo "==============================================================="
echo "🎙️  GERADOR DE AUDIOBOOK INTERATIVO AVANÇADO (PIPER TTS)"
echo "==============================================================="

if [ ! -f "$PIPER_BIN" ]; then
    echo "❌ Erro: O atalho '$PIPER_BIN' não foi encontrado."
    echo "Por favor, execute o script setup/setup-piper.sh primeiro."
    exit 1
fi

if [ ! -f "$SRT_ENTRADA" ]; then
    echo "❌ Erro: Arquivo SRT '$SRT_ENTRADA' não encontrado."
    echo "Este script agora trabalha apenas com o arquivo SRT fornecido."
    exit 1
fi

echo "✅ Arquivo SRT detectado: $SRT_ENTRADA"
echo "   O áudio final será gerado respeitando os intervalos definidos nele."

# 2. SELEÇÃO DE LOCOTOR
echo "---------------------------------------------------------------"
echo "1️⃣  Escolha a voz que deseja usar para narrar a história:"
echo "---------------------------------------------------------------"
echo "A) Jeff (Medium)   - Voz masculina, muito natural, ótima para livros"
echo "B) Faber (Medium)  - Voz masculina, ritmo firme e claro"
echo "C) Ricardo (Low)   - Voz masculina, modelo mais leve e rápido"
echo "D) Edresson (Low)  - Voz masculina, modelo tradicional leve"
echo "E) Gisela (Medium) - Voz feminina, excelente entonação e clareza"
echo ""
read -p "Digite a opção da voz (A, B, C, D ou E): " OPCAO_VOZ

# Converte para maiúsculo
OPCAO_VOZ=$(echo "$OPCAO_VOZ" | tr '[:lower:]' '[:upper:]')

case "$OPCAO_VOZ" in
    A)
        NOME_VOZ="Jeff (Medium)"
        SUFIXO_ARQUIVO="Jeff"
        MODELO="pt_BR-jeff-medium.onnx"
        URL_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/jeff/medium"
        ;;
    B)
        NOME_VOZ="Faber (Medium)"
        SUFIXO_ARQUIVO="Faber"
        MODELO="pt_BR-faber-medium.onnx"
        URL_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/faber/medium"
        ;;
    C)
        NOME_VOZ="Ricardo (Low)"
        SUFIXO_ARQUIVO="Ricardo"
        MODELO="pt_BR-ricardo-low.onnx"
        URL_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/ricardo/low"
        ;;
    D)
        NOME_VOZ="Edresson (Low)"
        SUFIXO_ARQUIVO="Edresson"
        MODELO="pt_BR-edresson-low.onnx"
        URL_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/edresson/low"
        ;;
    E)
        NOME_VOZ="Gisela (Medium)"
        SUFIXO_ARQUIVO="Gisela"
        MODELO="pt_BR-gisela-medium.onnx"
        URL_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/gisela/medium"
        ;;
    *)
        echo "❌ Opção de voz inválida! Encerrando script."
        exit 1
        ;;
esac

CONFIG_MODELO="${MODELO}.json"

# 3. SELEÇÃO DO TEMPO DE PAUSA (RITMO)
echo ""
echo "---------------------------------------------------------------"
echo "2️⃣  Escolha o tempo de pausa (silêncio) entre as frases:"
echo "---------------------------------------------------------------"
echo "1) 0.25s [Ritmo focado]  - Leitura bem dinâmica e direta"
echo "2) 0.50s [Padrão rádio] - Pausa curta, ritmo convencional de notícias"
echo "3) 0.75s [Narrador]     - Excelente equilíbrio para romances e histórias"
echo "4) 1.00s [Cadenciado]   - Ritmo relaxante, ótimo para ouvir descansando"
echo "5) Customizado          - Digite o seu próprio valor em segundos"
echo ""
read -p "Digite a opção do ritmo (1 a 5): " OPCAO_PAUSA

case "$OPCAO_PAUSA" in
    1) PAUSA_FRASE="0.25" ;;
    2) PAUSA_FRASE="0.50" ;;
    3) PAUSA_FRASE="0.75" ;;
    4) PAUSA_FRASE="1.00" ;;
    5)
        echo ""
        read -p "Digite o valor da pausa em segundos (ex: 0.6, 1.2, 1.5): " PAUSA_FRASE
        # Substitui vírgula por ponto caso o usuário digite "0,6"
        PAUSA_FRASE=$(echo "$PAUSA_FRASE" | tr ',' '.')
        ;;
    *)
        echo "ℹ️  Opção inválida. Aplicando o padrão rádio (0.50s)."
        PAUSA_FRASE="0.50"
        ;;
esac

# Define o nome do arquivo final usando a máscara: YYYY-MM-DD_NomeLocutor_output.wav
mkdir -p "$OUTPUT_DIR"
SAIDA="$OUTPUT_DIR/${DATA_ATUAL}_${SUFIXO_ARQUIVO}_output.wav"

echo ""
echo "==============================================================="
echo "🎙️  Voz selecionada: $NOME_VOZ"
echo "⏱️  Pausa entre frases: ${PAUSA_FRASE} segundos"
echo "💾 Arquivo de saída: $SAIDA"
echo "==============================================================="

# 4. Download Inteligente
MODELO_CAMINHO="$MODELS_DIR/$MODELO"
CONFIG_CAMINHO="$MODELS_DIR/$CONFIG_MODELO"

if [ ! -f "$MODELO_CAMINHO" ]; then
    echo "📥 Modelo '$MODELO' não encontrado. Baixando..."
    mkdir -p "$MODELS_DIR"
    wget -c "${URL_BASE}/${MODELO}" -O "$MODELO_CAMINHO"
else
    echo "✅ Modelo de voz já existe localmente."
fi

if [ ! -f "$CONFIG_CAMINHO" ]; then
    echo "📥 Configuração '$CONFIG_MODELO' não encontrada. Baixando..."
    mkdir -p "$MODELS_DIR"
    wget -c "${URL_BASE}/${CONFIG_MODELO}" -O "$CONFIG_CAMINHO"
else
    echo "✅ Arquivo de configuração já existe localmente."
fi

# 5. Processamento do Áudio
echo "---------------------------------------------------------------"
echo "🔊 Iniciando a síntese de voz com base apenas no SRT..."
echo "📄 Arquivo SRT utilizado: $SRT_ENTRADA"
echo "🕒 O áudio gerado seguirá exatamente os intervalos definidos no SRT."
echo "---------------------------------------------------------------"

if "$PYTHON_BIN" scripts/gerar-sincronizado.py \
    --srt "$SRT_ENTRADA" \
    --output "$SAIDA" \
    --model "$MODELO_CAMINHO" \
    --piper "$PIPER_BIN"; then
    echo ""
    echo "=================================================="
    echo "🎉 AUDIOBOOK SINCRONIZADO GERADO COM SUCESSO!"
    echo "🎙️  Voz utilizada: $NOME_VOZ"
    echo "🎵 Arquivo final: $SAIDA"
    echo "=================================================="
else
    echo "❌ Ocorreu um erro durante a geração sincronizada com o SRT."
    exit 1
fi
