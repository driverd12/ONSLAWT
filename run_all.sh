#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

if [[ -z "$RUN_ID" ]]; then
  RUN_ID=$(date +"%Y%m%d_%H%M%S")
fi

log() { echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*"; }

log "Running full ONSLAWT suite with run_id=$RUN_ID"

"$SCRIPT_DIR/run_iperf_tests.sh" -c "$CONFIG_PATH" -o "$OUT_BASE" -r "$RUN_ID" -t "$ONLY_TEST"
"$SCRIPT_DIR/run_latency_tests.sh" -c "$CONFIG_PATH" -o "$OUT_BASE" -r "$RUN_ID" -t "$ONLY_TEST"
"$SCRIPT_DIR/run_mtr.sh" -c "$CONFIG_PATH" -o "$OUT_BASE" -r "$RUN_ID" -t "$ONLY_TEST"
"$SCRIPT_DIR/run_mtu_tests.sh" -c "$CONFIG_PATH" -o "$OUT_BASE" -r "$RUN_ID" -t "$ONLY_TEST"
"$SCRIPT_DIR/run_speedtest.sh" -c "$CONFIG_PATH" -o "$OUT_BASE" -r "$RUN_ID" -t "$ONLY_TEST"

log "All tests complete. Results in $OUT_BASE/$RUN_ID"
