#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

HOST="${WEBAPP_HOST:-127.0.0.1}"
PORT="${WEBAPP_PORT:-8000}"
URL="http://$HOST:$PORT/"
LAN_IP=""
LAN_MODE="0"
VENV_DIR="${VENV_DIR:-$ROOT_DIR/.venv}"
VENV_PY="$VENV_DIR/bin/python"
MANAGE_PY="$ROOT_DIR/django_app/manage.py"

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return
  fi

  if has_cmd sudo; then
    sudo "$@"
    return
  fi

  echo "[webapp] operacao exige privilegio de administrador e 'sudo' nao foi encontrado"
  return 1
}

detect_os_family() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    local like="${ID_LIKE:-} ${ID:-}"
    case "$like" in
      *debian*|*ubuntu*)
        echo "debian"
        return
        ;;
      *fedora*|*rhel*|*centos*)
        echo "fedora"
        return
        ;;
    esac
  fi
  echo "unknown"
}

install_system_packages() {
  local os_family="$1"
  shift

  if [ "$#" -eq 0 ]; then
    return 0
  fi

  case "$os_family" in
    debian)
      run_privileged apt-get update -y
      run_privileged apt-get install -y "$@"
      ;;
    fedora)
      run_privileged dnf install -y "$@"
      ;;
    *)
      echo "[webapp] nao foi possivel instalar pacotes automaticamente neste SO"
      return 1
      ;;
  esac
}

resolve_lan_ip() {
  local ip_addr
  ip_addr="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  if [ -z "$ip_addr" ]; then
    ip_addr="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "$ip_addr"
}

ensure_lan_prereqs() {
  local os_family
  os_family="$(detect_os_family)"

  if ! has_cmd ip; then
    echo "[webapp] instalando dependencia: iproute2"
    install_system_packages "$os_family" iproute2 || true
  fi

  if ! has_cmd ufw && ! has_cmd firewall-cmd; then
    case "$os_family" in
      debian)
        echo "[webapp] instalando firewall utilitario: ufw"
        install_system_packages "$os_family" ufw || true
        ;;
      fedora)
        echo "[webapp] instalando firewall utilitario: firewalld"
        install_system_packages "$os_family" firewalld || true
        ;;
      *)
        echo "[webapp] nenhum utilitario de firewall detectado (ufw/firewalld)"
        ;;
    esac
  fi

  if has_cmd systemctl && has_cmd firewall-cmd; then
    run_privileged systemctl enable --now firewalld >/dev/null 2>&1 || true
  fi
}

open_firewall_port_if_possible() {
  if has_cmd ufw; then
    local ufw_status
    ufw_status="$(ufw status 2>/dev/null || true)"

    if printf '%s' "$ufw_status" | grep -qi "Status: active"; then
      if printf '%s' "$ufw_status" | grep -Eq "${PORT}/tcp[[:space:]].*ALLOW"; then
        echo "[webapp] porta ${PORT}/tcp ja liberada no ufw"
      else
        echo "[webapp] abrindo porta no ufw: ${PORT}/tcp"
        run_privileged ufw allow "${PORT}/tcp" >/dev/null
      fi
    else
      echo "[webapp] ufw detectado, mas inativo; sem alteracao de firewall"
    fi
    return 0
  fi

  if has_cmd firewall-cmd; then
    if has_cmd systemctl && systemctl is-active --quiet firewalld; then
      if firewall-cmd --quiet --query-port="${PORT}/tcp" >/dev/null 2>&1; then
        echo "[webapp] porta ${PORT}/tcp ja liberada no firewalld"
      else
        echo "[webapp] abrindo porta no firewalld: ${PORT}/tcp"
        run_privileged firewall-cmd --quiet --add-port="${PORT}/tcp"
        run_privileged firewall-cmd --quiet --runtime-to-permanent || true
      fi
    else
      echo "[webapp] firewalld detectado, mas inativo; sem alteracao de firewall"
    fi
    return 0
  fi

  echo "[webapp] nenhum firewall compativel detectado (ufw/firewalld); abra a porta ${PORT}/tcp manualmente, se necessario"
}

configure_lan_mode() {
  LAN_MODE="1"
  HOST="0.0.0.0"
  LAN_IP="$(resolve_lan_ip)"

  if [ -z "$LAN_IP" ]; then
    echo "[webapp] nao foi possivel detectar IP LAN automaticamente"
    LAN_IP="127.0.0.1"
  fi

  export WEBAPP_HOST="$HOST"
  export WEBAPP_PORT="$PORT"

  if [ -z "${DJANGO_ALLOWED_HOSTS:-}" ]; then
    export DJANGO_ALLOWED_HOSTS="127.0.0.1,localhost,${LAN_IP}"
  fi

  URL="http://${LAN_IP}:${PORT}/"
}

run_django_migrate() {
  if [ ! -x "$VENV_PY" ]; then
    echo "[webapp] venv nao encontrada em $VENV_PY"
    echo "[webapp] execute antes: bash workflows/webapp.sh setup"
    exit 1
  fi

  echo "[webapp] aplicando migracoes do Django..."
  "$VENV_PY" "$MANAGE_PY" migrate
}

usage() {
  cat <<'EOF'
Uso: bash workflows/webapp.sh <comando>

Comandos:
  setup        Instala dependencias Python e aplica migracoes
  start        Sobe web + worker em background (modo LAN)
  start-lan    Sobe web + worker para LAN (0.0.0.0) e tenta abrir porta no firewall
  stop         Para web + worker
  status       Mostra status dos processos
  restart      Reinicia web + worker (modo LAN)
  restart-lan  Reinicia web + worker para LAN (0.0.0.0)
  help         Mostra esta ajuda

Atalho:
  Se nenhum comando for informado, usa "start".
EOF
}

cmd="${1:-start}"

case "$cmd" in
  setup)
    bash scripts/webapp/setup_webapp.sh
    ;;
  start)
    ensure_lan_prereqs
    configure_lan_mode
    open_firewall_port_if_possible
    run_django_migrate
    bash scripts/webapp/start_webapp.sh
    echo "[webapp] LAN habilitada. Abra no navegador: $URL"
    ;;
  start-lan)
    ensure_lan_prereqs
    configure_lan_mode
    open_firewall_port_if_possible
    run_django_migrate
    bash scripts/webapp/start_webapp.sh
    echo "[webapp] LAN habilitada. Abra no navegador: $URL"
    ;;
  stop)
    bash scripts/webapp/stop_webapp.sh
    ;;
  status)
    bash scripts/webapp/status_webapp.sh
    echo "[webapp] URL configurada: $URL"
    ;;
  restart)
    ensure_lan_prereqs
    configure_lan_mode
    open_firewall_port_if_possible
    bash scripts/webapp/stop_webapp.sh || true
    run_django_migrate
    bash scripts/webapp/start_webapp.sh
    echo "[webapp] LAN habilitada. Abra no navegador: $URL"
    ;;
  restart-lan)
    ensure_lan_prereqs
    configure_lan_mode
    open_firewall_port_if_possible
    bash scripts/webapp/stop_webapp.sh || true
    run_django_migrate
    bash scripts/webapp/start_webapp.sh
    echo "[webapp] LAN habilitada. Abra no navegador: $URL"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "[webapp] comando invalido: $cmd"
    usage
    exit 1
    ;;
esac
