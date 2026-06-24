#!/usr/bin/env bash

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

INPUT_DIR="$ROOT_DIR/data/input"

if [ "${WORKFLOW_CLEANUP_DONE:-0}" != "1" ]; then
    export WORKFLOW_CLEANUP_DONE=1
    bash "$ROOT_DIR/workflows/5-limpar-outputs.sh" >/dev/null 2>&1 || true
fi

source "$ROOT_DIR/workflows/job_utils.sh"

job_reset_db_preserve_history
mkdir -p "$INPUT_DIR"

mapfile -t INPUT_FILES < <(find "$INPUT_DIR" -type f ! -name '.gitignore' ! -name '.gitkeep' | sort)

if [ "${#INPUT_FILES[@]}" -eq 0 ]; then
    echo "Nenhum arquivo encontrado em data/input/."
    echo "Adicione arquivos em data/input/ e execute novamente."
    exit 0
fi

echo "Reindexando arquivos de data/input/ no registro central (lista antiga limpa)..."
for full_path in "${INPUT_FILES[@]}"; do
    relative_path="${full_path#$ROOT_DIR/}"
    result="$(job_add_record "$relative_path")"
    job_id="${result%%|*}"

    echo "[NOVO] job $job_id -> $relative_path"
done

echo ""
echo "Registro atualizado em: workflows/jobs.md"
