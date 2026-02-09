#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEVICE_CHOICE="${DEVICE_CHOICE:-}"
PARALLEL_JOBS="${PARALLEL_JOBS:-1}"

if [[ -z "$DEVICE_CHOICE" ]]; then
  echo "Select gateway for this run:"
  echo "1) Meraki MX-450"
  echo "2) Palo Alto 3220"
  read -r -p "Enter choice (1/2): " DEVICE_CHOICE
fi

case "$DEVICE_CHOICE" in
  1|"meraki"|"mx"|"mx450"|"mx-450")
    DEVICE_LABEL="meraki_mx450"
    ;;
  2|"palo"|"paloalto"|"pa"|"pa-3220"|"3220")
    DEVICE_LABEL="palo_3220"
    ;;
  *)
    echo "Unknown choice. Set DEVICE_CHOICE=1 or 2 and re-run."
    exit 1
    ;;
 esac

RUN_ID="${DEVICE_LABEL}_$(date +"%Y%m%d_%H%M%S")"

PROFILE="${PROFILE:-quick}"
# Refresh public list for consistency
case "$PROFILE" in
  quick)
    "$SCRIPT_DIR/refresh_quick_tests.sh"
    ;;
  high)
    "$SCRIPT_DIR/refresh_high_tests.sh"
    ;;
  full|default|*)
    if [[ -x "$SCRIPT_DIR/refresh_public_tests.sh" ]]; then
      "$SCRIPT_DIR/refresh_public_tests.sh"
    fi
    ;;
esac

if [[ "$PARALLEL_JOBS" -gt 1 ]]; then
  "$SCRIPT_DIR/run_iperf_parallel.sh" -r "$RUN_ID"
else
  "$SCRIPT_DIR/run_iperf_tests.sh" -r "$RUN_ID"
fi

python3 "$SCRIPT_DIR/report_results.py" --run-dir "$SCRIPT_DIR/results/$RUN_ID" --device "$DEVICE_LABEL"

echo "Complete. Results in: $SCRIPT_DIR/results/$RUN_ID"
