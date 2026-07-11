#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

info() {
  echo
  echo "==> $*"
}

warn() {
  echo
  echo "[WARN] $*"
}

fail() {
  echo
  echo "[ERROR] $*" >&2
  exit 1
}

is_immutable_host() {
  [ -f /run/ostree-booted ] || command -v rpm-ostree >/dev/null 2>&1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

need_cmds() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! have_cmd "$cmd"; then
      missing+=("$cmd")
    fi
  done
  printf '%s\n' "${missing[@]:-}"
}

print_current_state() {
  echo "yt-dlp setup state:"
  echo "  yt-dlp: $(if have_cmd yt-dlp; then echo present; else echo missing; fi)"
  echo "  ffmpeg: $(if have_cmd ffmpeg; then echo present; else echo missing; fi)"
  echo "  node:   $(if have_cmd node; then echo present; else echo missing; fi)"
  echo "  deno:   $(if have_cmd deno; then echo present; else echo missing; fi)"
}

install_fedora_like() {
  info "Detectado Fedora/RHEL com dnf"
  $SUDO dnf install -y --skip-unavailable --skip-broken \
    yt-dlp \
    ffmpeg \
    nodejs
}

install_debian_like() {
  info "Detectado Debian/Ubuntu com apt-get"
  $SUDO apt-get update
  $SUDO apt-get install -y \
    yt-dlp \
    ffmpeg \
    nodejs
}

install_immutable_hint() {
  warn "Host imutável detectado. Instale as dependências em uma única transação e reinicie."
  echo
  echo "Pacotes sugeridos:"
  echo "  yt-dlp"
  echo "  ffmpeg"
  echo "  nodejs"
  echo
  echo "Exemplo:"
  echo "  sudo rpm-ostree install yt-dlp ffmpeg nodejs"
  echo "  systemctl reboot"
}

install_immutable_host_deps() {
  if ! have_cmd rpm-ostree; then
    install_immutable_hint
    return 1
  fi

  local packages=()
  if ! have_cmd yt-dlp; then
    packages+=(yt-dlp)
  fi
  if ! have_cmd ffmpeg; then
    packages+=(ffmpeg)
  fi
  if ! have_cmd node && ! have_cmd deno; then
    packages+=(nodejs)
  fi

  if [ "${#packages[@]}" -eq 0 ]; then
    info "Host imutável já tem yt-dlp, ffmpeg e um runtime JavaScript disponíveis"
    return 0
  fi

  info "Detectado host imutável com rpm-ostree; instalando dependências faltantes em uma única transação"
  echo "Pacotes: ${packages[*]}"
  $SUDO rpm-ostree install "${packages[@]}"
  warn "Instalação concluída; reinicie o sistema para ativar os novos pacotes."
  echo "Depois do reboot, execute novamente: ./setup/setup-ytdlp.sh"
  return 0
}

ensure_js_runtime() {
  if have_cmd node || have_cmd deno; then
    return 0
  fi

  if is_immutable_host; then
    if install_immutable_host_deps; then
      exit 0
    fi
    fail "Nenhum runtime JavaScript encontrado no PATH (node ou deno)."
  fi

  if have_cmd dnf; then
    install_fedora_like
  elif have_cmd apt-get; then
    install_debian_like
  else
    fail "Gerenciador de pacotes não suportado. Instale nodejs, ffmpeg e yt-dlp manualmente."
  fi

  if ! have_cmd node && ! have_cmd deno; then
    fail "Instalação concluída, mas nenhum runtime JavaScript ficou disponível no PATH."
  fi
}

ensure_core_tools() {
  local missing=()
  mapfile -t missing < <(need_cmds yt-dlp ffmpeg)
  local js_runtime_missing=0

  if ! have_cmd node && ! have_cmd deno; then
    js_runtime_missing=1
  fi

  if [ "${#missing[@]}" -eq 0 ] && [ "$js_runtime_missing" -eq 0 ]; then
    info "Dependências principais já estão disponíveis"
    return 0
  fi

  if is_immutable_host; then
    if [ "${#missing[@]}" -eq 0 ] && [ "$js_runtime_missing" -eq 0 ]; then
      fail "Runtime JavaScript ausente no host imutável."
    fi
    if install_immutable_host_deps; then
      exit 0
    fi

    local missing_msg="${missing[*]}"
    if [ "$js_runtime_missing" -eq 1 ]; then
      if [ -n "$missing_msg" ]; then
        missing_msg="$missing_msg nodejs/deno"
      else
        missing_msg="nodejs/deno"
      fi
    fi
    fail "Dependências faltando no host imutável: ${missing_msg}"
  fi

  if have_cmd dnf; then
    install_fedora_like
  elif have_cmd apt-get; then
    install_debian_like
  else
    fail "Gerenciador de pacotes não suportado. Instale yt-dlp, ffmpeg e nodejs manualmente."
  fi
}

main() {
  info "Preparando dependências do yt-dlp para o projeto"
  echo "Root do projeto: $ROOT_DIR"

  print_current_state
  ensure_core_tools
  ensure_js_runtime

  info "Verificando versão do yt-dlp"
  yt-dlp --version || true

  info "Verificando runtime JavaScript disponível"
  if have_cmd node; then
    node --version || true
  elif have_cmd deno; then
    deno --version || true
  fi

  info "Setup do yt-dlp concluído"
  echo "Use o botão Add novamente após reiniciar o webapp, se necessário."
}

main "$@"
