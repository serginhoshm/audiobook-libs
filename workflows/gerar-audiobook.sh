#!/bin/bash

set -e
set -o pipefail

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

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Setup logging
mkdir -p "$ROOT_DIR/logs"
LOG_FILE="$ROOT_DIR/logs/gerar-audiobook-${TIMESTAMP}.log"
SCRIPT_NAME="gerar-audiobook"
SCRIPT_START_TIME=$(date +%s)

# Source logging functions
source "$ROOT_DIR/scripts/log_helpers.sh"

{
log_header
echo "🎙️  GERADOR DE AUDIOBOOK INTERATIVO AVANÇADO (PIPER TTS)"
echo "==============================================================="

if [ ! -f "$PIPER_BIN" ]; then
    log_error "O atalho '$PIPER_BIN' não foi encontrado."
    log_summary "FALHA" "Piper não encontrado em $PIPER_BIN"
    exit 1
fi

if [ ! -f "$SRT_ENTRADA" ]; then
    log_error "Arquivo SRT '$SRT_ENTRADA' não encontrado."
    log_summary "FALHA" "Arquivo SRT ausente"
    exit 1
fi

echo "✅ Arquivo SRT detectado: $SRT_ENTRADA"
log_section "Seleção de Voz"
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
MODELO_CAMINHO="$MODELS_DIR/$MODELO"
CONFIG_CAMINHO="$MODELS_DIR/$CONFIG_MODELO"

# 3. SELEÇÃO DO TEMPO DE PAUSA (RITMO)
log_section "Seleção de Ritmo"
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

# Define o nome do arquivo final usando a máscara: output_YYYYMMDD_hhmmss.wav
mkdir -p "$OUTPUT_DIR"
SAIDA="$OUTPUT_DIR/output_${TIMESTAMP}.wav"

echo ""
echo "==============================================================="
echo "🎙️  Voz selecionada: $NOME_VOZ"
echo "⏱️  Pausa entre frases: ${PAUSA_FRASE} segundos"
echo "💾 Arquivo de saída: $SAIDA"
echo "==============================================================="

# 4. Download Inteligente
log_section "Verificação e Download de Modelo"
log_step "Preparando diretório de modelos"

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
log_section "Síntese de Voz"
log_step "Iniciando processamento do SRT"

if "$PYTHON_BIN" scripts/gerar-sincronizado.py \
    --srt "$SRT_ENTRADA" \
    --output "$SAIDA" \
    --model "$MODELO_CAMINHO" \
    --piper "$PIPER_BIN"; then
    log_step "Áudio sincronizado gerado com sucesso"
    log_summary "SUCCESS" ""
else
    log_error "Falha na geração sincronizada com o SRT."
    log_summary "FALHA" "Erro durante síntese de voz"
    exit 1
fi
} 2>&1 | tee -a "$LOG_FILE"
