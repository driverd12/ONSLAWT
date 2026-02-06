#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_PATH="$SCRIPT_DIR/tests.json"
OUT_BASE="$SCRIPT_DIR/results"
RUN_ID=""
ONLY_TEST=""
PARALLEL_JOBS="${PARALLEL_JOBS:-2}"
AUTO_REFRESH="${AUTO_REFRESH:-0}"

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

if [[ ! -f "$CONFIG_PATH" ]]; then
  if [[ "$AUTO_REFRESH" == "1" && -x "$SCRIPT_DIR/update_tests_from_public_list.py" ]]; then
    python3 "$SCRIPT_DIR/update_tests_from_public_list.py" --count 8 --continent "North America" --min-gbps 10 --udp-bandwidth "5G" --out "$CONFIG_PATH" --cache-dir "$SCRIPT_DIR/data"
  fi
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Config not found: $CONFIG_PATH" >&2
  exit 1
fi

if [[ "$PARALLEL_JOBS" -lt 1 ]]; then
  PARALLEL_JOBS=1
fi

mapfile -t TEST_NAMES < <(jq -r --arg name "$ONLY_TEST" '.tests[] | select(($name=="") or (.name==$name)) | .name' "$CONFIG_PATH")

if [[ "${#TEST_NAMES[@]}" -eq 0 ]]; then
  echo "No tests matched." >&2
  exit 1
fi

running=0

for name in "${TEST_NAMES[@]}"; do
  AUTO_REFRESH=0 "$SCRIPT_DIR/run_iperf_tests.sh" -c "$CONFIG_PATH" -o "$OUT_BASE" -r "$RUN_ID" -t "$name" &
  running=$((running + 1))

  if [[ "$running" -ge "$PARALLEL_JOBS" ]]; then
    wait -n
    running=$((running - 1))
  fi
done

wait
echo "Parallel run complete. Results in $OUT_BASE/$RUN_ID"
