#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 "$SCRIPT_DIR/update_tests_from_public_list.py" \
  --count 8 \
  --continent "North America" \
  --min-gbps 10 \
  --udp-bandwidth "5G" \
  --verify \
  --verify-timeout 8 \
  --verify-duration 2 \
  --out "$SCRIPT_DIR/tests.json" \
  --cache-dir "$SCRIPT_DIR/data"
