#!/usr/bin/env bash

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

INPUT_DIR="$ROOT_DIR/data/input"

source "$ROOT_DIR/workflows/job_utils.sh"

ensure_job_db
mkdir -p "$INPUT_DIR"

mapfile -t INPUT_FILES < <(find "$INPUT_DIR" -type f ! -name '.gitignore' ! -name '.gitkeep' | sort)

if [ "${#INPUT_FILES[@]}" -eq 0 ]; then
    echo "Nenhum arquivo encontrado em data/input/."
    echo "Adicione arquivos em data/input/ e execute novamente."
    exit 0
fi

echo "Indexando arquivos de data/input/ no registro central..."
for full_path in "${INPUT_FILES[@]}"; do
    relative_path="${full_path#$ROOT_DIR/}"
    result="$(job_add_record "$relative_path")"
    job_id="${result%%|*}"
    state="${result##*|}"

    if [ "$state" = "new" ]; then
        echo "[NOVO] job $job_id -> $relative_path"
    else
        echo "[EXISTENTE] job $job_id -> $relative_path"
    fi
done

echo ""
echo "Registro atualizado em: workflows/jobs.md"
