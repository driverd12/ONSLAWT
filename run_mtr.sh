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
require_cmd mtr

if [[ ! -f "$CONFIG_PATH" ]]; then
  die "Config not found: $CONFIG_PATH"
fi

if [[ -z "$RUN_ID" ]]; then
  RUN_ID=$(default_run_id)
fi

ensure_out_dir "$OUT_BASE" "$RUN_ID"

log "Starting mtr hop analysis using config: $CONFIG_PATH"

while IFS= read -r test_json; do
  name=$(config_get "$test_json" '.name')
  server_host=$(config_get "$test_json" '.server_host')
  mtr_host=$(config_get "$test_json" '.mtr_host')
  mtr_cycles=$(config_get "$test_json" '.mtr_cycles')
  run_mtr=$(config_get "$test_json" '.run_mtr')

  if [[ -z "$name" || -z "$server_host" ]]; then
    log "Skipping test with missing name or server_host."
    continue
  fi

  if [[ "$run_mtr" != "true" ]]; then
    log "[$name] run_mtr=false; skipping mtr."
    continue
  fi

  if [[ -z "$mtr_host" ]]; then mtr_host="$server_host"; fi
  if [[ -z "$mtr_cycles" ]]; then mtr_cycles="10"; fi

  ts=$(date -Iseconds)
  outfile="$OUT_DIR/mtr_${name}.json"

  log "[$name] Running mtr to ${mtr_host} (cycles=${mtr_cycles})."
  if ! mtr --report --json -c "$mtr_cycles" "$mtr_host" > "$outfile" 2>/dev/null; then
    log "[$name] mtr failed."
    continue
  fi

  meta=$(jq -n \
    --arg name "$name" \
    --arg tool "mtr" \
    --arg timestamp "$ts" \
    --arg host "$mtr_host" \
    --arg cycles "$mtr_cycles" \
    '{name:$name, tool:$tool, timestamp:$timestamp, host:$host, cycles:$cycles|tonumber }')

  tmpfile=$(mktemp)
  jq -n --argjson meta "$meta" --slurpfile result "$outfile" '{meta:$meta, result:$result[0]}' > "$tmpfile"
  mv "$tmpfile" "$outfile"

  log "[$name] Saved mtr report to $outfile"

done < <(config_get_tests "$CONFIG_PATH" "$ONLY_TEST")

log "mtr run complete."
