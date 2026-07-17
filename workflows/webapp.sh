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
OLLAMA_ENV_FILE="$ROOT_DIR/config/translation/ollama.env"

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_immutable_host() {
  [ -f /run/ostree-booted ] || has_cmd rpm-ostree
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

  echo "[webapp] operation requires admin privileges and 'sudo' was not found"
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

  if is_immutable_host; then
    echo "[webapp] immutable host detected; skipping automatic package installation"
    echo "[webapp] install manually (rpm-ostree/toolbox) if a dependency is missing: $*"
    return 1
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
      echo "[webapp] could not install packages automatically on this OS"
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

resolve_local_hostname() {
  local host_name
  host_name="$(hostname -s 2>/dev/null || true)"
  if [ -z "$host_name" ]; then
    host_name="$(hostname 2>/dev/null || true)"
  fi
  printf '%s' "$host_name"
}

ensure_lan_prereqs() {
  local os_family
  os_family="$(detect_os_family)"

  if ! has_cmd ip; then
    echo "[webapp] installing dependency: iproute2"
    install_system_packages "$os_family" iproute2 || true
  fi

  if ! has_cmd ufw && ! has_cmd firewall-cmd; then
    case "$os_family" in
      debian)
        echo "[webapp] installing firewall utility: ufw"
        install_system_packages "$os_family" ufw || true
        ;;
      fedora)
        echo "[webapp] installing firewall utility: firewalld"
        install_system_packages "$os_family" firewalld || true
        ;;
      *)
        echo "[webapp] no firewall utility detected (ufw/firewalld)"
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
        echo "[webapp] port ${PORT}/tcp is already open in ufw"
      else
        echo "[webapp] opening ufw port: ${PORT}/tcp"
        run_privileged ufw allow "${PORT}/tcp" >/dev/null
      fi
    else
      echo "[webapp] ufw detected but inactive; no firewall changes applied"
    fi
    return 0
  fi

  if has_cmd firewall-cmd; then
    if has_cmd systemctl && systemctl is-active --quiet firewalld; then
      if firewall-cmd --quiet --query-port="${PORT}/tcp" >/dev/null 2>&1; then
        echo "[webapp] port ${PORT}/tcp is already open in firewalld"
      else
        echo "[webapp] opening firewalld port: ${PORT}/tcp"
        run_privileged firewall-cmd --quiet --add-port="${PORT}/tcp"
        run_privileged firewall-cmd --quiet --runtime-to-permanent || true
      fi
    else
      echo "[webapp] firewalld detected but inactive; no firewall changes applied"
    fi
    return 0
  fi

  echo "[webapp] no compatible firewall detected (ufw/firewalld); open port ${PORT}/tcp manually if needed"
}

configure_lan_mode() {
  LAN_MODE="1"
  HOST="0.0.0.0"
  LAN_IP="$(resolve_lan_ip)"

  if [ -z "$LAN_IP" ]; then
    echo "[webapp] could not detect LAN IP automatically"
    LAN_IP="127.0.0.1"
  fi

  export WEBAPP_HOST="$HOST"
  export WEBAPP_PORT="$PORT"

  if [ -z "${DJANGO_ALLOWED_HOSTS:-}" ]; then
    local host_name
    host_name="$(resolve_local_hostname)"
    if [ -n "$host_name" ]; then
      export DJANGO_ALLOWED_HOSTS="127.0.0.1,localhost,${LAN_IP},${host_name}"
    else
      export DJANGO_ALLOWED_HOSTS="127.0.0.1,localhost,${LAN_IP}"
    fi
  fi

  URL="http://${LAN_IP}:${PORT}/"
}

run_django_migrate() {
  if [ ! -x "$VENV_PY" ]; then
    echo "[webapp] virtual environment not found at $VENV_PY"
    echo "[webapp] run first: bash workflows/webapp.sh setup"
    exit 1
  fi

  if ! "$VENV_PY" -c "import django" >/dev/null 2>&1; then
    echo "[webapp] Django is missing in venv; running setup_webapp automatically..."
    bash scripts/webapp/setup_webapp.sh
  fi

  echo "[webapp] applying Django migrations..."
  "$VENV_PY" "$MANAGE_PY" migrate
}

maybe_setup_ollama() {
  local backend="${TRANSLATION_BACKEND:-}"
  local auto_detected="0"
  local setup_script=""

  # Load local Ollama settings if available so setup uses project-specific host/model.
  if [ -f "$OLLAMA_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$OLLAMA_ENV_FILE"
    backend="${backend:-ollama}"
  fi

  if [ -z "$backend" ] && has_cmd podman && podman container exists ollama >/dev/null 2>&1; then
    backend="ollama"
    auto_detected="1"
  fi

  if [ "$backend" != "ollama" ]; then
    return 0
  fi

  if has_cmd apt-get || has_cmd ollama; then
    setup_script="$ROOT_DIR/setup/setup-ollama-linux.sh"
  elif has_cmd podman; then
    setup_script="$ROOT_DIR/setup/setup-ollama-bluefin.sh"
  else
    setup_script="$ROOT_DIR/setup/setup-ollama-linux.sh"
  fi

  if [ ! -x "$setup_script" ] && [ ! -f "$setup_script" ]; then
    echo "[webapp] ollama backend selected, but no compatible setup script was found"
    return 1
  fi

  if [ "$auto_detected" = "1" ]; then
    echo "[webapp] detected local Ollama environment; running model bootstrap"
  else
    echo "[webapp] ollama backend detected; running setup with model bootstrap"
  fi
  bash "$setup_script"
}

usage() {
  cat <<'EOF'
Usage: bash workflows/webapp.sh <command>

Commands:
  setup        Install Python dependencies and apply migrations
  start        Start web + worker in background (LAN mode)
  start-lan    Start web + worker for LAN (0.0.0.0) and try opening firewall port
  stop         Stop web + worker
  status       Show process status
  restart      Restart web + worker (LAN mode)
  restart-lan  Restart web + worker for LAN (0.0.0.0)
  help         Show this help

Shortcut:
  If no command is provided, defaults to "start".
EOF
}

cmd="${1:-start}"

case "$cmd" in
  setup)
    bash scripts/webapp/setup_webapp.sh
    maybe_setup_ollama
    ;;
  start)
    ensure_lan_prereqs
    configure_lan_mode
    open_firewall_port_if_possible
    run_django_migrate
    bash scripts/webapp/start_webapp.sh
    echo "[webapp] LAN enabled. Open in browser: $URL"
    ;;
  start-lan)
    ensure_lan_prereqs
    configure_lan_mode
    open_firewall_port_if_possible
    run_django_migrate
    bash scripts/webapp/start_webapp.sh
    echo "[webapp] LAN enabled. Open in browser: $URL"
    ;;
  stop)
    bash scripts/webapp/stop_webapp.sh
    ;;
  status)
    bash scripts/webapp/status_webapp.sh
    echo "[webapp] configured URL: $URL"
    ;;
  restart)
    ensure_lan_prereqs
    configure_lan_mode
    open_firewall_port_if_possible
    bash scripts/webapp/stop_webapp.sh || true
    run_django_migrate
    bash scripts/webapp/start_webapp.sh
    echo "[webapp] LAN enabled. Open in browser: $URL"
    ;;
  restart-lan)
    ensure_lan_prereqs
    configure_lan_mode
    open_firewall_port_if_possible
    bash scripts/webapp/stop_webapp.sh || true
    run_django_migrate
    bash scripts/webapp/start_webapp.sh
    echo "[webapp] LAN enabled. Open in browser: $URL"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "[webapp] invalid command: $cmd"
    usage
    exit 1
    ;;
esac
