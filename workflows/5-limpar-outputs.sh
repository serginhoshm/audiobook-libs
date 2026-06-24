#!/usr/bin/env bash

set -e
set -o pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

INPUT_DIR="$ROOT_DIR/data/input"
OUTPUT_DIR="$ROOT_DIR/data/outputs"
ARCHIVE_DIR="$OUTPUT_DIR/archive"

source "$ROOT_DIR/workflows/job_utils.sh"

mkdir -p "$ROOT_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$ROOT_DIR/logs/limpar-outputs-${TIMESTAMP}.log"
SCRIPT_NAME="limpar-outputs"
SCRIPT_START_TIME=$(date +%s)

source "$ROOT_DIR/scripts/log_helpers.sh"

{
    log_header
    log_section "Preparacao"

    mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$ARCHIVE_DIR"

    # Mantem a estrutura de archive versionada no git, ignorando o conteudo.
    touch "$OUTPUT_DIR/.gitkeep"
    touch "$ARCHIVE_DIR/.gitkeep"
    if [ ! -f "$ARCHIVE_DIR/.gitignore" ]; then
        cat > "$ARCHIVE_DIR/.gitignore" <<'EOF'
*
!.gitkeep
!.gitignore
EOF
    fi

    mapfile -t INPUT_AUDIO_FILES < <(
        find "$INPUT_DIR" -type f \( -iname '*.wav' -o -iname '*.mp3' \) | sort
    )

    if [ "${#INPUT_AUDIO_FILES[@]}" -eq 0 ]; then
        log_step "Nenhum arquivo .wav/.mp3 encontrado em $INPUT_DIR"
        log_summary "SUCCESS" "Sem itens para arquivar"
        exit 0
    fi

    moved_count=0
    scanned_count=0

    shopt -s nullglob

    for input_file in "${INPUT_AUDIO_FILES[@]}"; do
        scanned_count=$((scanned_count + 1))
        input_base="$(basename "${input_file%.*}")"
        input_slug="$(job_slug "$input_base")"

        if [ -z "$input_slug" ]; then
            log_step "Ignorando (slug vazio): $input_file"
            continue
        fi

        declare -A seen=()
        candidates=()

        for file in \
            "$OUTPUT_DIR"/job_*_"$input_slug"_*.json \
            "$OUTPUT_DIR"/job_*_"$input_slug"_*.pt.srt \
            "$OUTPUT_DIR"/job_*_"$input_slug"_*.srt \
            "$OUTPUT_DIR"/job_*_"$input_slug"_*.tsv \
            "$OUTPUT_DIR"/job_*_"$input_slug"_*.txt \
            "$OUTPUT_DIR"/job_*_"$input_slug"_*.vtt \
            "$OUTPUT_DIR"/job_*_"$input_slug".pt.srt
        do
            [ -f "$file" ] || continue
            if [ -z "${seen[$file]:-}" ]; then
                seen[$file]=1
                candidates+=("$file")
            fi
        done

        if [ "${#candidates[@]}" -eq 0 ]; then
            log_step "Sem outputs correspondentes para: $(basename "$input_file")"
            continue
        fi

        log_section "Arquivando outputs de $(basename "$input_file")"
        for artifact in "${candidates[@]}"; do
            target="$ARCHIVE_DIR/$(basename "$artifact")"
            mv -f "$artifact" "$target"
            moved_count=$((moved_count + 1))
            log_step "Movido: $(basename "$artifact") -> $ARCHIVE_DIR"
        done
    done

    shopt -u nullglob

    log_section "Resumo"
    log_step "Entradas avaliadas (.wav/.mp3): $scanned_count"
    log_step "Arquivos movidos para archive: $moved_count"
    log_summary "SUCCESS" ""
} 2>&1 | tee -a "$LOG_FILE"
