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

speedtest_cmd=()
if command -v speedtest >/dev/null 2>&1; then
  speedtest_cmd=(speedtest --accept-license --accept-gdpr -f json)
elif command -v speedtest-cli >/dev/null 2>&1; then
  speedtest_cmd=(speedtest-cli --json)
else
  die "speedtest or speedtest-cli is required for speed tests."
fi

log "Starting speedtest runs using config: $CONFIG_PATH"

while IFS= read -r test_json; do
  name=$(config_get "$test_json" '.name')
  run_speedtest=$(config_get "$test_json" '.run_speedtest')
  test_type=$(config_get "$test_json" '.type')

  if [[ -z "$name" ]]; then
    log "Skipping test with missing name."
    continue
  fi

  if [[ "$run_speedtest" != "true" && "$test_type" != "speedtest" ]]; then
    continue
  fi

  ts=$(date -Iseconds)
  outfile="$OUT_DIR/speedtest_${name}.json"

  log "[$name] Running speedtest."
  if ! "${speedtest_cmd[@]}" > "$outfile" 2>/dev/null; then
    log "[$name] speedtest failed."
    continue
  fi

  meta=$(jq -n \
    --arg name "$name" \
    --arg tool "speedtest" \
    --arg timestamp "$ts" \
    '{name:$name, tool:$tool, timestamp:$timestamp}')

  tmpfile=$(mktemp)
  jq -n --argjson meta "$meta" --slurpfile result "$outfile" '{meta:$meta, result:$result[0]}' > "$tmpfile"
  mv "$tmpfile" "$outfile"

  log "[$name] Saved speedtest results to $outfile"

done < <(config_get_tests "$CONFIG_PATH" "$ONLY_TEST")

log "Speedtest run complete."
