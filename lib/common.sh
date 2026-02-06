#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log() {
  local ts
  ts=$(date +"%Y-%m-%d %H:%M:%S")
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "[$ts] $*" | tee -a "$LOG_FILE"
  else
    echo "[$ts] $*"
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

default_run_id() {
  date +"%Y%m%d_%H%M%S"
}

ensure_out_dir() {
  local base="$1"
  local run_id="$2"
  OUT_DIR="$base/$run_id"
  mkdir -p "$OUT_DIR"
  LOG_FILE="$OUT_DIR/run.log"
  touch "$LOG_FILE"
}

config_get_tests() {
  local cfg="$1"
  local only="$2"
  jq -c --arg name "$only" '.defaults as $d | .tests[] | select(($name=="") or (.name==$name)) | $d + .' "$cfg"
}

config_get() {
  local json="$1"
  local path="$2"
  local val
  val=$(jq -r "$path // empty" <<<"$json")
  echo "$val"
}

ssh_run() {
  local user="$1"
  local host="$2"
  local port="$3"
  local key="$4"
  local opts="$5"
  local cmd="$6"

  local ssh_args=()
  if [[ -n "$port" ]]; then
    ssh_args+=("-p" "$port")
  fi
  if [[ -n "$key" ]]; then
    ssh_args+=("-i" "$key")
  fi
  ssh_args+=("-o" "BatchMode=yes" "-o" "ConnectTimeout=5" "-o" "StrictHostKeyChecking=accept-new")

  if [[ -n "$opts" ]]; then
    # shellcheck disable=SC2206
    local extra_opts=($opts)
    ssh_args+=("${extra_opts[@]}")
  fi

  ssh "${ssh_args[@]}" "${user}@${host}" "$cmd"
}

maybe_start_iperf_server() {
  local name="$1"
  local server_host="$2"
  local iperf_port="$3"
  local start_server="$4"
  local ssh_user="$5"
  local ssh_host="$6"
  local ssh_port="$7"
  local ssh_key="$8"
  local ssh_opts="$9"

  if [[ "$start_server" != "true" ]]; then
    log "[$name] start_server=false, assuming iperf3 server already running."
    return 0
  fi

  if [[ -n "$ssh_user" && -n "$ssh_host" ]]; then
    log "[$name] Starting iperf3 server on ${ssh_host}:${iperf_port} via SSH."
    ssh_run "$ssh_user" "$ssh_host" "$ssh_port" "$ssh_key" "$ssh_opts" \
      "nohup iperf3 -s -1 -p $iperf_port >/tmp/iperf3_${name}.log 2>&1 &"
    sleep 1
    return 0
  fi

  if [[ "$server_host" == "127.0.0.1" || "$server_host" == "localhost" ]]; then
    log "[$name] Starting local iperf3 server on ${server_host}:${iperf_port}."
    nohup iperf3 -s -1 -p "$iperf_port" >/tmp/iperf3_${name}.log 2>&1 &
    sleep 1
    return 0
  fi

  log "[$name] No SSH info provided; skipping server start. Ensure iperf3 server is running on ${server_host}:${iperf_port}."
}
