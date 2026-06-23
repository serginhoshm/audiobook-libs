#!/bin/bash
# Funções auxiliares para logging estruturado

# Variables set by caller:
# - SCRIPT_NAME: nome do script (ex: gerar-audiobook)
# - LOG_FILE: caminho completo do arquivo de log
# - SCRIPT_START_TIME: timestamp de início (segundos desde epoch)

log_header() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║ [INICIO] $SCRIPT_NAME"
    echo "║ Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "║ Log: $LOG_FILE"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
}

log_section() {
    local section="$1"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "▶ $section"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

log_step() {
    local step="$1"
    echo "  ✓ $step"
}

log_error() {
    local error="$1"
    echo "  ✗ ERRO: $error" >&2
}

log_summary() {
    local status="$1"
    local error_msg="${2:-}"
    
    local script_end_time=$(date +%s)
    local elapsed=$((script_end_time - SCRIPT_START_TIME))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))
    local time_str=$(printf "%02d:%02d:%02d" $hours $minutes $seconds)
    
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    if [ "$status" = "SUCCESS" ]; then
        echo "║ [SUCESSO] $SCRIPT_NAME"
    else
        echo "║ [FALHA] $SCRIPT_NAME"
    fi
    echo "║ Status: $status"
    echo "║ Tempo: $time_str"
    if [ -n "$error_msg" ]; then
        echo "║ Erro: $error_msg"
    fi
    echo "║ Finalizado: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
}

export -f log_header log_section log_step log_error log_summary
