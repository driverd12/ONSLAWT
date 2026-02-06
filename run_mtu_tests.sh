#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIG_PATH="$SCRIPT_DIR/tests.json"
OUT_BASE="$SCRIPT_DIR/results"
RUN_ID=""
ONLY_TEST=""

usage() {
  cat <<USAGE
Usage: $0 [-c tests.json] [-o results_dir] [-r run_id] [-t test_name]
USAGE
}

while getopts ":c:o:r:t:h" opt; do
  case "$opt" in
    c) CONFIG_PATH="$OPTARG" ;;
    o) OUT_BASE="$OPTARG" ;;
    r) RUN_ID="$OPTARG" ;;
    t) ONLY_TEST="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

require_cmd jq

if [[ ! -f "$CONFIG_PATH" ]]; then
  die "Config not found: $CONFIG_PATH"
fi

if [[ -z "$RUN_ID" ]]; then
  RUN_ID=$(default_run_id)
fi

ensure_out_dir "$OUT_BASE" "$RUN_ID"

log "Starting MTU discovery using config: $CONFIG_PATH"

tracepath_mtu() {
  local host="$1"
  local output
  output=$(tracepath -n "$host" 2>/dev/null | head -n 5)
  local mtu
  mtu=$(echo "$output" | grep -m1 -o 'pmtu [0-9]*' | awk '{print $2}')
  echo "$mtu|$output"
}

ping_mtu() {
  local host="$1"
  local max_size="$2"
  local min_size="$3"
  local size="$max_size"
  local success_size=""

  while (( size >= min_size )); do
    if ping -M do -c 1 -s "$size" "$host" >/dev/null 2>&1; then
      success_size="$size"
      break
    fi
    size=$((size - 10))
  done

  if [[ -n "$success_size" ]]; then
    echo $((success_size + 28))
  else
    echo ""
  fi
}

while IFS= read -r test_json; do
  name=$(config_get "$test_json" '.name')
  server_host=$(config_get "$test_json" '.server_host')
  mtu_host=$(config_get "$test_json" '.mtu_host')
  mtu_test=$(config_get "$test_json" '.mtu_test')
  mtu_max_size=$(config_get "$test_json" '.mtu_max_size')
  mtu_min_size=$(config_get "$test_json" '.mtu_min_size')
  run_mtu=$(config_get "$test_json" '.run_mtu')

  if [[ -z "$name" || -z "$server_host" ]]; then
    log "Skipping test with missing name or server_host."
    continue
  fi

  if [[ "$run_mtu" != "true" || "$mtu_test" != "true" ]]; then
    log "[$name] mtu_test=false or run_mtu=false; skipping MTU discovery."
    continue
  fi

  if [[ -z "$mtu_host" ]]; then mtu_host="$server_host"; fi
  if [[ -z "$mtu_max_size" ]]; then mtu_max_size="1472"; fi
  if [[ -z "$mtu_min_size" ]]; then mtu_min_size="1200"; fi

  ts=$(date -Iseconds)
  outfile="$OUT_DIR/mtu_${name}.json"

  mtu=""
  raw=""
  method=""

  if command -v tracepath >/dev/null 2>&1; then
    method="tracepath"
    result=$(tracepath_mtu "$mtu_host")
    mtu=$(echo "$result" | cut -d'|' -f1)
    raw=$(echo "$result" | cut -d'|' -f2-)
  elif ping -M do -c 1 -s 1472 127.0.0.1 >/dev/null 2>&1; then
    method="ping"
    mtu=$(ping_mtu "$mtu_host" "$mtu_max_size" "$mtu_min_size")
    raw=""
  else
    log "[$name] Neither tracepath nor ping -M do available. Skipping MTU discovery."
    continue
  fi

  summary=$(jq -n --arg mtu "$mtu" '{mtu: ($mtu|tonumber?)}')
  meta=$(jq -n \
    --arg name "$name" \
    --arg tool "mtu" \
    --arg timestamp "$ts" \
    --arg host "$mtu_host" \
    --arg method "$method" \
    '{name:$name, tool:$tool, timestamp:$timestamp, host:$host, method:$method}')

  jq -n --argjson meta "$meta" --argjson summary "$summary" --arg raw "$raw" \
    '{meta:$meta, summary:$summary, raw:$raw}' > "$outfile"

  log "[$name] Saved MTU results to $outfile"

done < <(config_get_tests "$CONFIG_PATH" "$ONLY_TEST")

log "MTU discovery complete."
