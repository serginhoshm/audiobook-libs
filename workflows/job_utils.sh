#!/usr/bin/env bash

JOB_DB_FILE="${JOB_DB_FILE:-$ROOT_DIR/workflows/jobs.md}"

job_write_db_template() {
    mkdir -p "$(dirname "$JOB_DB_FILE")"
    cat > "$JOB_DB_FILE" <<'EOF'
# Job Registry

This file is the central workflow database mapping job ids to input files.

| Job ID | Job Code | File Name | Relative Path | Created At |
| --- | --- | --- | --- | --- |

## Step History

| Timestamp | Job ID | Job Code | Workflow Step | Status | Details |
| --- | --- | --- | --- | --- | --- |
EOF
}

job_write_db_jobs_header_only() {
    mkdir -p "$(dirname "$JOB_DB_FILE")"
    cat > "$JOB_DB_FILE" <<'EOF'
# Job Registry

This file is the central workflow database mapping job ids to input files.

| Job ID | Job Code | File Name | Relative Path | Created At |
| --- | --- | --- | --- | --- |

EOF
}

job_trim() {
    local value="$1"
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    printf "%s" "$value"
}

job_slug() {
    local raw="$1"
    printf "%s" "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

job_normalize_id() {
    local raw="$1"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        printf "%04d" "$raw"
        return 0
    fi

    if [[ "$raw" =~ ^[Jj]([0-9]+)$ ]]; then
        printf "%04d" "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

job_code_from_id() {
    local normalized_id="$1"
    printf "J%s" "$normalized_id"
}

job_output_base() {
    local normalized_id="$1"
    local file_name="$2"
    local base_name="${file_name%.*}"
    local slug
    slug="$(job_slug "$base_name")"
    printf "job_%s_%s" "$normalized_id" "$slug"
}

ensure_job_db() {
    if [ ! -f "$JOB_DB_FILE" ]; then
    job_write_db_template
        return 0
    fi

    if ! grep -q "^## Step History" "$JOB_DB_FILE"; then
        cat >> "$JOB_DB_FILE" <<'EOF'

## Step History

| Timestamp | Job ID | Job Code | Workflow Step | Status | Details |
| --- | --- | --- | --- | --- | --- |
EOF
    fi
}

job_reset_db() {
    job_write_db_template
}

job_reset_db_preserve_history() {
    ensure_job_db

    local tmp_history
    tmp_history="$(mktemp)"

    awk '
        BEGIN { in_step_history = 0 }
        $0 == "## Step History" { in_step_history = 1 }
        in_step_history { print }
    ' "$JOB_DB_FILE" > "$tmp_history"

    if [ ! -s "$tmp_history" ]; then
        cat > "$tmp_history" <<'EOF'
## Step History

| Timestamp | Job ID | Job Code | Workflow Step | Status | Details |
| --- | --- | --- | --- | --- | --- |
EOF
    fi

    job_write_db_jobs_header_only
    cat "$tmp_history" >> "$JOB_DB_FILE"
    rm -f "$tmp_history"
}

job_list_records() {
    ensure_job_db
    awk -F'|' '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        /^\|/ {
            id = trim($2)
            code = trim($3)
            name = trim($4)
            path = trim($5)
            if (id ~ /^[0-9]{4}$/) {
                print id "|" code "|" name "|" path
            }
        }
    ' "$JOB_DB_FILE"
}

job_prompt_select_id() {
    ensure_job_db

    local rows=()
    mapfile -t rows < <(job_list_records)

    if [ "${#rows[@]}" -eq 0 ]; then
        echo "Nenhum job encontrado em workflows/jobs.md." >&2
        echo "Adicione arquivos em data/input/ e execute workflows/0-indexar-inputs.sh." >&2
        return 1
    fi

    echo "" >&2
    echo "Selecione um job para executar:" >&2
    local i=1
    local row
    for row in "${rows[@]}"; do
        IFS='|' read -r id code file_name relative_path <<< "$row"
        echo "  $i) [$code] $file_name ($relative_path)" >&2
        i=$((i + 1))
    done
    echo "" >&2

    local choice
    read -r -p "Digite o numero da lista ou Job ID: " choice >&2
    choice="$(job_trim "$choice")"

    local normalized
    if normalized="$(job_normalize_id "$choice" 2>/dev/null)"; then
        if job_get_record_by_id "$normalized" >/dev/null 2>&1; then
            printf "%s" "$normalized"
            return 0
        fi
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#rows[@]}" ]; then
        row="${rows[$((choice - 1))]}"
        IFS='|' read -r id _ <<< "$row"
        printf "%s" "$id"
        return 0
    fi

    echo "Selecao invalida." >&2
    return 1
}

job_record_step() {
    local job_id="$1"
    local job_code="$2"
    local workflow_step="$3"
    local status="$4"
    local details="${5:-}"

    ensure_job_db
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    printf "| %s | %s | %s | %s | %s | %s |\n" \
        "$timestamp" "$job_id" "$job_code" "$workflow_step" "$status" "$details" >> "$JOB_DB_FILE"
}

job_get_id_by_path() {
    local relative_path="$1"
    ensure_job_db

    awk -F'|' -v target="$relative_path" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        /^\|/ {
            id = trim($2)
            path = trim($5)
            if (id ~ /^[0-9]{4}$/ && path == target) {
                print id
                exit
            }
        }
    ' "$JOB_DB_FILE"
}

job_find_next_id() {
    ensure_job_db

    local max_id
    max_id="$(awk -F'|' '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        /^\|/ {
            id = trim($2)
            if (id ~ /^[0-9]{4}$/) {
                num = id + 0
                if (num > max) max = num
            }
        }
        END { printf "%d", max }
    ' "$JOB_DB_FILE")"

    printf "%04d" "$((max_id + 1))"
}

job_add_record() {
    local relative_path="$1"
    ensure_job_db

    local existing_id
    existing_id="$(job_get_id_by_path "$relative_path")"
    if [ -n "$existing_id" ]; then
        printf "%s|existing" "$existing_id"
        return 0
    fi

    local next_id
    next_id="$(job_find_next_id)"
    local code
    code="$(job_code_from_id "$next_id")"
    local file_name
    file_name="$(basename "$relative_path")"
    local created_at
    created_at="$(date '+%Y-%m-%d %H:%M:%S')"

    printf "| %s | %s | %s | %s | %s |\n" "$next_id" "$code" "$file_name" "$relative_path" "$created_at" >> "$JOB_DB_FILE"
    printf "%s|new" "$next_id"
}

job_get_record_by_id() {
    local id_input="$1"
    ensure_job_db

    local normalized_id
    if ! normalized_id="$(job_normalize_id "$id_input")"; then
        return 1
    fi

    local row
    row="$(awk -F'|' -v target="$normalized_id" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        /^\|/ {
            id = trim($2)
            if (id == target) {
                code = trim($3)
                name = trim($4)
                path = trim($5)
                print id "\t" code "\t" name "\t" path
                exit
            }
        }
    ' "$JOB_DB_FILE")"

    if [ -z "$row" ]; then
        return 1
    fi

    JOB_ID="$(printf "%s" "$row" | cut -f1)"
    JOB_CODE="$(printf "%s" "$row" | cut -f2)"
    JOB_FILE_NAME="$(printf "%s" "$row" | cut -f3)"
    JOB_RELATIVE_PATH="$(printf "%s" "$row" | cut -f4)"
    export JOB_ID JOB_CODE JOB_FILE_NAME JOB_RELATIVE_PATH
}
