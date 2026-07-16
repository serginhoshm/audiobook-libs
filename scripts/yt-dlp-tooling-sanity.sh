#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose:
# - Install/upgrade yt-dlp
# - Run sanity checks for tooling that yt-dlp commonly benefits from
# - Do NOT run anything related to this repo pipeline/app

YTDLP_TEST_URL="${YTDLP_TEST_URL:-https://youtu.be/DSvmSVkKK6o}"
# Default behavior now runs the full flow automatically:
# 1) install/upgrade attempts (including apt via sudo)
# 2) network metadata probe with yt-dlp
RUN_NETWORK_TEST="${RUN_NETWORK_TEST:-1}"
INSTALL_WITH_SUDO_APT="${INSTALL_WITH_SUDO_APT:-1}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

have() {
  command -v "$1" >/dev/null 2>&1
}

upgrade_ytdlp_with_python() {
  local py="$1"
  log "Trying upgrade via: $py -m pip install -U yt-dlp"
  if "$py" -m pip install -U yt-dlp; then
    return 0
  fi

  warn "Global/venv pip upgrade failed for $py, trying --user"
  if "$py" -m pip install --user -U yt-dlp; then
    return 0
  fi

  warn "pip install also failed for $py (possibly PEP 668 externally-managed environment)"
  return 1
}

upgrade_or_install_ytdlp_with_pipx() {
  if ! have pipx; then
    return 1
  fi

  log "Trying pipx path for yt-dlp"
  if pipx list 2>/dev/null | grep -qi 'package yt-dlp'; then
    pipx upgrade yt-dlp && return 0
  fi

  pipx install yt-dlp && return 0
  return 1
}

install_ytdlp_with_apt_if_enabled() {
  if [[ "$INSTALL_WITH_SUDO_APT" != "1" ]]; then
    return 1
  fi

  if ! have sudo || ! have apt-get; then
    warn "INSTALL_WITH_SUDO_APT=1 set, but sudo/apt-get is unavailable"
    return 1
  fi

  log "Installing yt-dlp via apt (sudo)"
  sudo apt-get update && sudo apt-get install -y yt-dlp
}

print_tool_version() {
  local tool="$1"
  local args="$2"
  if have "$tool"; then
    printf 'OK    %-14s %s\n' "$tool" "$("$tool" $args 2>/dev/null | head -n 1 || true)"
  else
    printf 'MISS  %-14s %s\n' "$tool" "not found"
  fi
}

main() {
  log "Starting yt-dlp tooling setup/sanity (no app/pipeline actions)."
  log "Flow: install/upgrade tooling first, then run sanity checks and yt-dlp network probe."

  install_ok=0

  if have python3; then
    if upgrade_ytdlp_with_python python3; then
      install_ok=1
    else
      warn "Could not upgrade yt-dlp with python3"
    fi
  else
    warn "python3 not found; cannot upgrade yt-dlp via pip"
  fi

  if [[ $install_ok -eq 0 ]]; then
    if upgrade_or_install_ytdlp_with_pipx; then
      install_ok=1
    else
      warn "pipx path did not complete"
    fi
  fi

  if [[ $install_ok -eq 0 ]]; then
    if install_ytdlp_with_apt_if_enabled; then
      install_ok=1
    else
      warn "apt path failed"
    fi
  fi

  # Final guidance if yt-dlp is still missing from PATH.
  if ! have yt-dlp; then
    warn "yt-dlp still not found in PATH after install attempts."
    warn "If needed, install with: sudo apt-get update && sudo apt-get install -y yt-dlp"
    warn "Or with pipx: pipx install yt-dlp"
  fi

  if [[ "$INSTALL_WITH_SUDO_APT" == "1" ]]; then
    log "apt install path is ENABLED by default (INSTALL_WITH_SUDO_APT=1)."
  else
    log "apt install path is DISABLED (INSTALL_WITH_SUDO_APT=0)."
  fi

  echo
  log "Version checks"
  print_tool_version yt-dlp "--version"
  print_tool_version python3 "--version"
  print_tool_version ffmpeg "-version"
  print_tool_version ffprobe "-version"
  print_tool_version node "--version"
  print_tool_version deno "--version"
  print_tool_version bun "--version"
  print_tool_version qjs "--version"
  print_tool_version npm "--version"
  print_tool_version aria2c "--version"
  print_tool_version python3 "-m yt_dlp --version"

  echo
  log "yt-dlp feature checks"
  if have yt-dlp; then
    if yt-dlp --help 2>/dev/null | grep -q -- '--js-runtimes'; then
      echo "OK    yt-dlp supports --js-runtimes"
    else
      echo "WARN  yt-dlp does not expose --js-runtimes option"
    fi

    if yt-dlp --help 2>/dev/null | grep -q -- '--extractor-args'; then
      echo "OK    yt-dlp supports --extractor-args"
    else
      echo "WARN  yt-dlp does not expose --extractor-args option"
    fi
  else
    echo "MISS  yt-dlp is unavailable; skipping feature checks"
  fi

  echo
  log "JS runtime hint"
  if have node || have deno || have bun || have qjs; then
    echo "OK    At least one JS runtime is present for extractor JS challenges"
  else
    echo "WARN  No JS runtime found (node/deno/bun/qjs). Some YouTube extractions may fail."
  fi

  echo
  log "PATH checks"
  if have yt-dlp; then
    echo "yt-dlp path: $(command -v yt-dlp)"
  fi
  if have python3; then
    echo "python3 path: $(command -v python3)"
    python3 -m pip --version || true
  fi
  if have pipx; then
    echo "pipx path: $(command -v pipx)"
    pipx --version || true
  fi

  echo
  log "Network sanity (yt-dlp metadata only, no download)"
  if [[ "$RUN_NETWORK_TEST" == "1" ]]; then
    if have yt-dlp; then
      set +e
      yt-dlp \
        --ignore-config \
        --no-playlist \
        --skip-download \
        --dump-single-json \
        --extractor-args "youtube:player_client=web" \
        "$YTDLP_TEST_URL" \
        >/tmp/yt_dlp_probe.json 2>/tmp/yt_dlp_probe.err
      rc=$?
      set -e
      if [[ $rc -eq 0 ]]; then
        echo "OK    yt-dlp metadata probe succeeded"
      else
        echo "WARN  yt-dlp metadata probe failed (exit=$rc)"
        echo "--- stderr (last 30 lines) ---"
        tail -n 30 /tmp/yt_dlp_probe.err || true
      fi
    else
      echo "MISS  yt-dlp unavailable; skipping network sanity"
    fi
  else
    echo "SKIP  RUN_NETWORK_TEST=0"
  fi

  echo
  log "Done."
}

main "$@"
