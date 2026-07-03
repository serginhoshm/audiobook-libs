#!/bin/bash

# --- CONFIGURAÇÃO ---
HOST="192.168.1.200"
USER="filmes"
PASS='filmes123*' # Aspas simples protegem o asterisco no Bash
REMOTE_DIR="ab-work/remux"
LOCAL_DIR="/home/publicar"

# Comando exato que será registrado no cron
CRON_COMMAND="lftp -u $USER,$PASS -e \"mirror --remove-source-files $REMOTE_DIR $LOCAL_DIR; quit\" $HOST"
# Agendamento do cron: Executar a cada 30 minutos
CRON_SCHEDULE="*/30 * * * *"

# --- PASSO 1: Criar pasta local se não existir ---
if [ ! -d "$LOCAL_DIR" ]; then
    echo "Criando o diretório local $LOCAL_DIR..."
    mkdir -p "$LOCAL_DIR"
fi

# --- PASSO 2: Verificar e remover Cron Jobs duplicados ---
echo "Verificando se já existe um cron job idêntico..."

# Captura o crontab atual do usuário
CRON_ACTUAL=$(crontab -l 2>/dev/null)

if echo "$CRON_ACTUAL" | grep -Fq "$CRON_COMMAND"; then
    echo "Job duplicado encontrado. Removendo a versão antiga..."
    # Filtra o crontab atual, removendo a linha antiga e salvando de volta
    echo "$CRON_ACTUAL" | grep -v -F "$CRON_COMMAND" | crontab -
else
    echo "Nenhum job duplicado encontrado."
fi

# --- PASSO 3: Agendar o novo trabalho no Cron ---
echo "Agendando o novo trabalho no cron (a cada 30 minutos)..."
(crontab -l 2>/dev/null; echo "$CRON_SCHEDULE $CRON_COMMAND") | crontab -

echo "Tudo pronto! O script foi agendado para rodar na seguinte programação: $CRON_SCHEDULE"