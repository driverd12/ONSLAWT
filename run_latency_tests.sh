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

log "Starting latency tests using config: $CONFIG_PATH"

parse_fping_line() {
  local line="$1"
  local loss min avg max
  loss=$(echo "$line" | sed -n 's/.*%loss = [0-9]*\/[0-9]*\/\([0-9.]*\)%.*/\1/p')
  min=$(echo "$line" | sed -n 's/.*min\/avg\/max = \([0-9.]*\)\/.*/\1/p')
  avg=$(echo "$line" | sed -n 's/.*min\/avg\/max = [0-9.]*\/\([0-9.]*\)\/.*/\1/p')
  max=$(echo "$line" | sed -n 's/.*min\/avg\/max = [0-9.]*\/[0-9.]*\/\([0-9.]*\).*/\1/p')
  echo "$min|$avg|$max|$loss"
}

parse_ping_output() {
  local output="$1"
  local loss min avg max
  local loss_line rtt_line
  loss_line=$(echo "$output" | grep -E 'packet loss' | tail -n 1 || true)
  loss=$(echo "$loss_line" | sed -n 's/.*\([0-9.]*\)% packet loss.*/\1/p')

  rtt_line=$(echo "$output" | grep -E 'min/avg/max' | tail -n 1 || true)
  # Linux: rtt min/avg/max/mdev = 0.042/0.049/0.058/0.006 ms
  # macOS: round-trip min/avg/max/stddev = 10.123/11.456/13.789/0.321 ms
  min=$(echo "$rtt_line" | sed -n 's/.*= \([0-9.]*\)\/\([0-9.]*\)\/\([0-9.]*\)\/.*$/\1/p')
  avg=$(echo "$rtt_line" | sed -n 's/.*= [0-9.]*\/\([0-9.]*\)\/\([0-9.]*\)\/.*$/\1/p')
  max=$(echo "$rtt_line" | sed -n 's/.*= [0-9.]*\/[0-9.]*\/\([0-9.]*\)\/.*$/\1/p')
  echo "$min|$avg|$max|$loss"
}

while IFS= read -r test_json; do
  name=$(config_get "$test_json" '.name')
  server_host=$(config_get "$test_json" '.server_host')
  latency_host=$(config_get "$test_json" '.latency_host')
  ping_count=$(config_get "$test_json" '.ping_count')
  ping_interval_ms=$(config_get "$test_json" '.ping_interval_ms')
  ping_pause_ms=$(config_get "$test_json" '.ping_pause_ms')
  ping_bursts=$(config_get "$test_json" '.ping_bursts')
  run_latency=$(config_get "$test_json" '.run_latency')

  if [[ -z "$name" || -z "$server_host" ]]; then
    log "Skipping test with missing name or server_host."
    continue
  fi

  if [[ "$run_latency" != "true" ]]; then
    log "[$name] run_latency=false; skipping latency tests."
    continue
  fi

  if [[ -z "$latency_host" ]]; then latency_host="$server_host"; fi
  if [[ -z "$ping_count" ]]; then ping_count="20"; fi
  if [[ -z "$ping_interval_ms" ]]; then ping_interval_ms="2"; fi
  if [[ -z "$ping_pause_ms" ]]; then ping_pause_ms="500"; fi
  if [[ -z "$ping_bursts" ]]; then ping_bursts="1"; fi

  raw_tmp=$(mktemp)

  log "[$name] Running latency tests to ${latency_host} (${ping_bursts} burst(s), ${ping_count} packets, ${ping_interval_ms}ms interval)."

  burst_file=$(mktemp)
  mins=()
  avgs=()
  maxs=()
  losses=()

  for ((i=1; i<=ping_bursts; i++)); do
    if command -v fping >/dev/null 2>&1; then
      line=$(fping -c "$ping_count" -p "$ping_interval_ms" -q "$latency_host" 2>&1 | tail -n 1 || true)
      echo "$line" >> "$raw_tmp"
      parsed=$(parse_fping_line "$line")
    else
      # Try a very fast interval first; if it fails, fall back to 200ms.
      if ping -c "$ping_count" -i 0.002 "$latency_host" >/dev/null 2>&1; then
        output=$(ping -c "$ping_count" -i 0.002 "$latency_host" 2>&1 | tail -n 10)
      else
        output=$(ping -c "$ping_count" -i 0.2 "$latency_host" 2>&1 | tail -n 10)
      fi
      echo "$output" >> "$raw_tmp"
      parsed=$(parse_ping_output "$output")
    fi

    min_val=$(echo "$parsed" | cut -d'|' -f1)
    avg_val=$(echo "$parsed" | cut -d'|' -f2)
    max_val=$(echo "$parsed" | cut -d'|' -f3)
    loss_val=$(echo "$parsed" | cut -d'|' -f4)

    mins+=("$min_val")
    avgs+=("$avg_val")
    maxs+=("$max_val")
    losses+=("$loss_val")

    jq -n --arg min "$min_val" --arg avg "$avg_val" --arg max "$max_val" --arg loss "$loss_val" \
      '{min_ms: ($min|tonumber?), avg_ms: ($avg|tonumber?), max_ms: ($max|tonumber?), loss_percent: ($loss|tonumber?)}' >> "$burst_file"

    if (( i < ping_bursts )); then
      sleep $(awk "BEGIN {print $ping_pause_ms/1000}")
    fi
  done

  bursts=$(jq -s '.' "$burst_file")

  avg_min=$(printf '%s\n' "${mins[@]}" | awk '{if($1!=""){sum+=$1; n++}} END{if(n>0) printf "%.3f", sum/n; else print ""}')
  avg_avg=$(printf '%s\n' "${avgs[@]}" | awk '{if($1!=""){sum+=$1; n++}} END{if(n>0) printf "%.3f", sum/n; else print ""}')
  max_max=$(printf '%s\n' "${maxs[@]}" | awk 'BEGIN{max=-1} {if($1!="" && $1>max) max=$1} END{if(max>=0) printf "%.3f", max; else print ""}')
  avg_loss=$(printf '%s\n' "${losses[@]}" | awk '{if($1!=""){sum+=$1; n++}} END{if(n>0) printf "%.3f", sum/n; else print ""}')

  summary=$(jq -n --arg min "$avg_min" --arg avg "$avg_avg" --arg max "$max_max" --arg loss "$avg_loss" \
    '{min_ms: ($min|tonumber?), avg_ms: ($avg|tonumber?), max_ms: ($max|tonumber?), loss_percent: ($loss|tonumber?)}')

  ts=$(date -Iseconds)
  outfile="$OUT_DIR/latency_${name}.json"

  meta=$(jq -n \
    --arg name "$name" \
    --arg tool "latency" \
    --arg timestamp "$ts" \
    --arg host "$latency_host" \
    --arg ping_count "$ping_count" \
    --arg ping_interval_ms "$ping_interval_ms" \
    --arg ping_bursts "$ping_bursts" \
    '{name:$name, tool:$tool, timestamp:$timestamp, host:$host,
      ping_count:$ping_count|tonumber, ping_interval_ms:$ping_interval_ms|tonumber, ping_bursts:$ping_bursts|tonumber }')

  raw=$(cat "$raw_tmp")

  jq -n --argjson meta "$meta" --argjson summary "$summary" --argjson bursts "$bursts" --arg raw "$raw" \
    '{meta:$meta, summary:$summary, bursts:$bursts, raw:$raw}' > "$outfile"

  rm -f "$burst_file" "$raw_tmp"
  log "[$name] Saved latency results to $outfile"

done < <(config_get_tests "$CONFIG_PATH" "$ONLY_TEST")

log "Latency test run complete."
