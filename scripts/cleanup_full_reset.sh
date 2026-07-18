#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
INI_PATH="$ROOT_DIR/config/pipeline.ini"
DB_PATH="$ROOT_DIR/django_app/db.sqlite3"

if [[ ! -f "$INI_PATH" ]]; then
  echo "[erro] INI nao encontrado: $INI_PATH" >&2
  exit 1
fi

if [[ ! -f "$DB_PATH" ]]; then
  echo "[erro] Banco SQLite nao encontrado: $DB_PATH" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[erro] python3 nao encontrado no PATH." >&2
  exit 1
fi

DATA_ROOT="$(python3 - "$INI_PATH" "$ROOT_DIR" <<'PY'
import configparser
import pathlib
import sys

ini_path = pathlib.Path(sys.argv[1])
root_dir = pathlib.Path(sys.argv[2])

cfg = configparser.ConfigParser(interpolation=None)
cfg.read(ini_path, encoding="utf-8")
raw = cfg.get("paths", "data_root_relative", fallback="data").strip()

if raw.startswith("/"):
    print(pathlib.Path(raw))
else:
    print(root_dir / raw)
PY
)"

EXEC_DIR="$DATA_ROOT/exec"
TEMP_DIR="$DATA_ROOT/temp"
THUMBS_DIR="$DATA_ROOT/thumbs"
DATA_LOGS_DIR="$DATA_ROOT/logs"

CODE="$(printf "%04d-%02d" "$((RANDOM % 10000))" "$((RANDOM % 100))")"

echo "=========================================="
echo " LIMPEZA COMPLETA (DESTRUTIVA)"
echo "=========================================="
echo "Banco SQLite: $DB_PATH"
echo "Pasta exec:   $EXEC_DIR"
echo "Pasta temp:   $TEMP_DIR"
echo "Pasta thumbs: $THUMBS_DIR"
echo "Logs data:    $DATA_LOGS_DIR"
echo
echo "Para continuar, digite o codigo: $CODE"
read -r -p "> " TYPED_CODE

if [[ "$TYPED_CODE" != "$CODE" ]]; then
  echo "[cancelado] Codigo incorreto. Nenhuma alteracao foi feita."
  exit 1
fi

echo
read -r -p "Confirma a limpeza completa? (sim/nao): " CONFIRM
CONFIRM_LC="$(printf '%s' "$CONFIRM" | tr '[:upper:]' '[:lower:]')"

if [[ "$CONFIRM_LC" != "sim" && "$CONFIRM_LC" != "s" ]]; then
  echo "[cancelado] Operacao abortada pelo usuario."
  exit 1
fi

count_entries() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    echo 0
    return
  fi
  find "$dir" -mindepth 1 | wc -l
}

wipe_dir_contents() {
  local dir="$1"
  mkdir -p "$dir"
  find "$dir" -mindepth 1 -exec rm -rf -- {} +
}

echo
echo "[1/5] Limpando registros do SQLite..."
python3 - "$DB_PATH" <<'PY'
import sqlite3
import sys

path = sys.argv[1]
conn = sqlite3.connect(path, timeout=30)
conn.execute("PRAGMA foreign_keys=OFF")
cur = conn.cursor()

tables = [
    row[0]
    for row in cur.execute(
        """
        SELECT name
        FROM sqlite_master
        WHERE type='table'
          AND name NOT LIKE 'sqlite_%'
          AND name <> 'django_migrations'
        ORDER BY name
        """
    )
]

total_deleted = 0
for table in tables:
    row_count = cur.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
    if row_count:
      total_deleted += int(row_count)
    cur.execute(f'DELETE FROM "{table}"')

cur.execute("DELETE FROM sqlite_sequence")
conn.commit()
cur.execute("VACUUM")
conn.close()

print(f"tabelas_limpas={len(tables)}")
print(f"registros_apagados={total_deleted}")
PY

echo "[2/5] Removendo thumbnails..."
THUMBS_BEFORE="$(count_entries "$THUMBS_DIR")"
wipe_dir_contents "$THUMBS_DIR"

echo "[3/5] Removendo logs..."
DATA_LOGS_BEFORE="$(count_entries "$DATA_LOGS_DIR")"
wipe_dir_contents "$DATA_LOGS_DIR"

echo "[4/5] Removendo arquivos da pasta exec..."
EXEC_BEFORE="$(count_entries "$EXEC_DIR")"
wipe_dir_contents "$EXEC_DIR"

echo "[5/5] Removendo arquivos da pasta temp..."
TEMP_BEFORE="$(count_entries "$TEMP_DIR")"
wipe_dir_contents "$TEMP_DIR"

echo
echo "=========================================="
echo " LIMPEZA CONCLUIDA"
echo "=========================================="
echo "thumbs removidos (entradas):   $THUMBS_BEFORE"
echo "logs data removidos (entradas): $DATA_LOGS_BEFORE"
echo "exec removidos (entradas):      $EXEC_BEFORE"
echo "temp removidos (entradas):      $TEMP_BEFORE"
echo
echo "Diretorios mantidos para reuso."
