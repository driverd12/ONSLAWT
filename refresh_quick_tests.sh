#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 "$SCRIPT_DIR/update_tests_from_public_list.py" \
  --count 3 \
  --continent "North America" \
  --min-gbps 10 \
  --protocols "tcp" \
  --duration 8 \
  --parallel 2 \
  --direction "bidirectional" \
  --runs-per-test 1 \
  --udp-bandwidth "3G" \
  --out "$SCRIPT_DIR/tests.json" \
  --cache-dir "$SCRIPT_DIR/data" \
  --verify \
  --verify-timeout 8 \
  --verify-duration 2
