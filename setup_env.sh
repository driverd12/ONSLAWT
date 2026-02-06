#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*"; }

detect_os() {
  uname -s
}

install_with_apt() {
  log "Installing dependencies with apt..."
  sudo apt-get update -y
  sudo apt-get install -y iperf3 mtr fping jq iputils-tracepath python3 python3-pip
  if ! command -v speedtest-cli >/dev/null 2>&1; then
    sudo pip3 install speedtest-cli
  fi
}

install_with_dnf() {
  log "Installing dependencies with dnf..."
  sudo dnf install -y iperf3 mtr fping jq iputils python3 python3-pip
  if ! command -v speedtest-cli >/dev/null 2>&1; then
    sudo pip3 install speedtest-cli
  fi
}

install_with_yum() {
  log "Installing dependencies with yum..."
  sudo yum install -y iperf3 mtr fping jq iputils python3 python3-pip
  if ! command -v speedtest-cli >/dev/null 2>&1; then
    sudo pip3 install speedtest-cli
  fi
}

install_with_pacman() {
  log "Installing dependencies with pacman..."
  sudo pacman -Sy --noconfirm iperf3 mtr fping jq iputils python python-pip
  if ! command -v speedtest-cli >/dev/null 2>&1; then
    sudo pip install speedtest-cli
  fi
}

install_with_brew() {
  log "Installing dependencies with brew..."
  brew install iperf3 mtr fping jq iputils speedtest-cli python
}

main() {
  os=$(detect_os)
  case "$os" in
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        install_with_apt
      elif command -v dnf >/dev/null 2>&1; then
        install_with_dnf
      elif command -v yum >/dev/null 2>&1; then
        install_with_yum
      elif command -v pacman >/dev/null 2>&1; then
        install_with_pacman
      else
        log "Unsupported Linux package manager. Install iperf3, mtr, fping, jq, tracepath, python3, and speedtest-cli manually."
        exit 1
      fi
      ;;
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        install_with_brew
      else
        log "Homebrew not found. Install Homebrew or install dependencies manually."
        exit 1
      fi
      ;;
    *)
      log "Unsupported OS: $os. Install dependencies manually."
      exit 1
      ;;
  esac

  log "Dependency setup complete."
}

main "$@"
