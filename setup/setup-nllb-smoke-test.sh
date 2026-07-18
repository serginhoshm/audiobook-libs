#!/usr/bin/env bash

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_PYTHON="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"

NLLB_MODEL_DIR="${NLLB_MODEL_DIR:-$ROOT_DIR/models/nllb/facebook-nllb-200-distilled-600M}"
SOURCE_LANG="${SOURCE_LANG:-zh-CN}"
SMOKE_STRICT_QUALITY="${SMOKE_STRICT_QUALITY:-0}"

DATA_ROOT="$(python3 "$ROOT_DIR/scripts/resolve_data_root.py" data-root)"
LOG_DIR="$DATA_ROOT/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/setup-nllb-smoke-test-${TIMESTAMP}.log"
SCRIPT_NAME="setup-nllb-smoke-test"
SCRIPT_START_TIME="$(date +%s)"

LOG_HELPER="$ROOT_DIR/scripts/pipeline_logging.py"
if [ -x "$VENV_PYTHON" ]; then
  LOG_PYTHON="$VENV_PYTHON"
else
  LOG_PYTHON="$(command -v python3 || true)"
fi

log_header() {
  if [ -n "$LOG_PYTHON" ] && [ -f "$LOG_HELPER" ]; then
    "$LOG_PYTHON" "$LOG_HELPER" header --script-name "$SCRIPT_NAME" --log-file "$LOG_FILE"
  fi
}

log_section() {
  local section="$1"
  if [ -n "$LOG_PYTHON" ] && [ -f "$LOG_HELPER" ]; then
    "$LOG_PYTHON" "$LOG_HELPER" section --title "$section"
  fi
}

log_step() {
  local step="$1"
  if [ -n "$LOG_PYTHON" ] && [ -f "$LOG_HELPER" ]; then
    "$LOG_PYTHON" "$LOG_HELPER" step --message "$step"
  else
    echo "  ✓ $step"
  fi
}

log_error() {
  local error="$1"
  if [ -n "$LOG_PYTHON" ] && [ -f "$LOG_HELPER" ]; then
    "$LOG_PYTHON" "$LOG_HELPER" error --message "$error"
  else
    echo "  ✗ ERROR: $error" >&2
  fi
}

log_summary() {
  local status="$1"
  local error_msg="${2:-}"
  if [ -n "$LOG_PYTHON" ] && [ -f "$LOG_HELPER" ]; then
    "$LOG_PYTHON" "$LOG_HELPER" summary \
      --script-name "$SCRIPT_NAME" \
      --status "$status" \
      --start-time "$SCRIPT_START_TIME" \
      --error-message "$error_msg"
  fi
}

{
  log_header

  log_section "Validacoes Iniciais"
  if [ ! -x "$VENV_PYTHON" ]; then
    log_error "Python nao encontrado/executavel: $VENV_PYTHON"
    log_summary "FALHA" "Python ausente"
    exit 1
  fi

  if [ ! -d "$NLLB_MODEL_DIR" ]; then
    log_error "Diretorio do modelo NLLB nao encontrado: $NLLB_MODEL_DIR"
    log_summary "FALHA" "Modelo ausente"
    exit 1
  fi

  case "$(printf '%s' "$SOURCE_LANG" | tr '[:upper:]' '[:lower:]')" in
    zh-cn|es)
      ;;
    *)
      log_error "SOURCE_LANG invalido para smoke test: $SOURCE_LANG (use zh-CN ou es)"
      log_summary "FALHA" "Idioma invalido"
      exit 1
      ;;
  esac

  log_step "Python: $VENV_PYTHON"
  log_step "Modelo NLLB: $NLLB_MODEL_DIR"
  log_step "Idioma de origem para teste: $SOURCE_LANG"
  log_step "Modo estrito de qualidade: $SMOKE_STRICT_QUALITY"

  log_section "Smoke Test"
  TMP_DIR="$(mktemp -d)"
  INPUT_SRT="$TMP_DIR/smoke_input.srt"
  OUTPUT_SRT="$TMP_DIR/smoke_output.srtpt"

  if [ "$(printf '%s' "$SOURCE_LANG" | tr '[:upper:]' '[:lower:]')" = "zh-cn" ]; then
    TEST_TEXT_1="我今天终于回家了。"
    TEST_TEXT_2="会议推迟到下周三上午九点。"
    TEST_TEXT_3="这家店的咖啡很香，但有点贵。"
    TEST_TEXT_4="请把蓝色文件夹放在第二个抽屉里。"
    TEST_TEXT_5="昨晚下雨了，所以路上很滑。"
    TEST_TEXT_6="这段故事讲的是一位年轻工程师在山区修复一座老桥。起初，村民不信任他，因为过去很多项目都半途而废。后来，他每天和大家一起搬材料、测量地形，还主动教孩子们基础科学知识。几个月后，桥梁正式通车，村里第一次有了稳定的货运线路。"
    TEST_TEXT_7="第二段内容讨论的是城市里的小型菜园计划。居民把闲置屋顶改造成种植区，轮流负责浇水和堆肥管理。学校也参与其中，学生每周记录植物生长数据，并学习如何减少食物浪费。这个计划不仅改善了社区关系，还让很多家庭的蔬菜开销明显下降。"
  else
    TEST_TEXT_1="Hoy finalmente regresé a casa."
    TEST_TEXT_2="La reunión se aplazó al miércoles a las nueve."
    TEST_TEXT_3="El café de esta tienda es excelente, pero caro."
    TEST_TEXT_4="Guarda la carpeta azul en el segundo cajón."
    TEST_TEXT_5="Anoche llovió, por eso la calle está resbaladiza."
    TEST_TEXT_6="Este relato trata de una joven ingeniera que restaura un puente antiguo en una región montañosa. Al principio, los vecinos desconfiaban porque muchos proyectos anteriores quedaron incompletos. Con el tiempo, ella trabajó con la comunidad todos los días, enseñó nociones de ciencia a los niños y coordinó el transporte de materiales. Meses después, el puente abrió y el pueblo obtuvo una ruta comercial estable por primera vez."
    TEST_TEXT_7="El segundo texto habla de huertos urbanos en azoteas compartidas. Los residentes organizaron turnos para regar, compostar y registrar la producción semanal. Las escuelas se sumaron con actividades de observación y análisis de datos de crecimiento. Además de mejorar la convivencia, el proyecto redujo el desperdicio de alimentos y el gasto mensual en verduras para muchas familias."
  fi

  cat > "$INPUT_SRT" <<EOF
1
00:00:00,000 --> 00:00:03,500
$TEST_TEXT_1

2
00:00:04,000 --> 00:00:07,500
$TEST_TEXT_2

3
00:00:08,000 --> 00:00:11,500
$TEST_TEXT_3

4
00:00:12,000 --> 00:00:15,500
$TEST_TEXT_4

5
00:00:16,000 --> 00:00:19,500
$TEST_TEXT_5

6
00:00:20,000 --> 00:00:33,000
$TEST_TEXT_6

7
00:00:34,000 --> 00:00:47,000
$TEST_TEXT_7

EOF

  log_step "Executando traduzir.py com backend nllb_local"
  "$VENV_PYTHON" "$ROOT_DIR/scripts/traduzir.py" \
    "$INPUT_SRT" \
    "$OUTPUT_SRT" \
    "$SOURCE_LANG" \
    --backend nllb_local \
    --nllb-model-dir "$NLLB_MODEL_DIR"

  if [ ! -f "$OUTPUT_SRT" ]; then
    log_error "Arquivo de saida nao foi gerado: $OUTPUT_SRT"
    log_summary "FALHA" "Sem saida"
    rm -rf "$TMP_DIR"
    exit 1
  fi

  mapfile -t TRANSLATED_LINES < <(awk '{if ($0 !~ /^$/ && $0 !~ /^[0-9]+$/ && $0 !~ /-->/) print}' "$OUTPUT_SRT")
  if [ "${#TRANSLATED_LINES[@]}" -lt 7 ]; then
    log_error "Nao foi possivel extrair todas as traducoes esperadas da saida (${#TRANSLATED_LINES[@]}/7)"
    log_summary "FALHA" "Traducao vazia"
    rm -rf "$TMP_DIR"
    exit 1
  fi

  log_step "Caso 1 (curto) original: $TEST_TEXT_1"
  log_step "Caso 1 (curto) traduzido: ${TRANSLATED_LINES[0]}"
  log_step "Caso 2 (curto) original: $TEST_TEXT_2"
  log_step "Caso 2 (curto) traduzido: ${TRANSLATED_LINES[1]}"
  log_step "Caso 3 (curto) original: $TEST_TEXT_3"
  log_step "Caso 3 (curto) traduzido: ${TRANSLATED_LINES[2]}"
  log_step "Caso 4 (curto) original: $TEST_TEXT_4"
  log_step "Caso 4 (curto) traduzido: ${TRANSLATED_LINES[3]}"
  log_step "Caso 5 (curto) original: $TEST_TEXT_5"
  log_step "Caso 5 (curto) traduzido: ${TRANSLATED_LINES[4]}"
  log_step "Caso 6 (longo) original: $TEST_TEXT_6"
  log_step "Caso 6 (longo) traduzido: ${TRANSLATED_LINES[5]}"
  log_step "Caso 7 (longo) original: $TEST_TEXT_7"
  log_step "Caso 7 (longo) traduzido: ${TRANSLATED_LINES[6]}"

  log_section "Qualidade Minima"
  SUSPECT_PATTERNS=(
    "caixao"
    "caixão"
    "choveu a chuva"
    "cheio de ar"
  )

  suspect_hits=0
  for translated_line in "${TRANSLATED_LINES[@]}"; do
    lowered_line="$(printf '%s' "$translated_line" | tr '[:upper:]' '[:lower:]')"
    for pattern in "${SUSPECT_PATTERNS[@]}"; do
      if [[ "$lowered_line" == *"$pattern"* ]]; then
        suspect_hits=$((suspect_hits + 1))
        log_error "Termo suspeito detectado: '$pattern' em '$translated_line'"
      fi
    done
  done

  if [ "$suspect_hits" -gt 0 ]; then
    if [ "$SMOKE_STRICT_QUALITY" = "1" ]; then
      log_summary "FALHA" "Qualidade abaixo do minimo (hits=$suspect_hits)"
      rm -rf "$TMP_DIR"
      exit 1
    fi
    log_step "Qualidade minima: ALERTA (hits=$suspect_hits, sem falhar em modo nao estrito)"
  else
    log_step "Qualidade minima: OK"
  fi

  rm -rf "$TMP_DIR"

  log_summary "SUCCESS" ""
  echo
  echo "Smoke test NLLB finalizado com sucesso."
  echo "Log: $LOG_FILE"
} 2>&1 | tee -a "$LOG_FILE"
