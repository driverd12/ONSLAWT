#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 "$SCRIPT_DIR/update_tests_from_public_list.py" \
  --count 5 \
  --continent "North America" \
  --min-gbps 10 \
  --protocols "tcp,udp" \
  --duration 12 \
  --parallel 3 \
  --direction "bidirectional" \
  --runs-per-test 1 \
  --udp-bandwidth "5G" \
  --adaptive-udp \
  --udp-start "2G" \
  --udp-step "2G" \
  --udp-max "10G" \
  --udp-loss 1.0 \
  --udp-jitter 5.0 \
  --udp-drop 5.0 \
  --out "$SCRIPT_DIR/tests.json" \
  --cache-dir "$SCRIPT_DIR/data" \
  --verify \
  --verify-timeout 8 \
  --verify-duration 2
