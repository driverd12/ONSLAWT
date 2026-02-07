#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CONFIG_PATH="$SCRIPT_DIR/tests.json"
OUT_BASE="$SCRIPT_DIR/results"
RUN_ID=""
ONLY_TEST=""
AUTO_REFRESH="${AUTO_REFRESH:-1}"

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
require_cmd iperf3

if [[ ! -f "$CONFIG_PATH" ]]; then
  # Attempt to auto-refresh if configured.
  if [[ "$AUTO_REFRESH" == "1" && -x "$SCRIPT_DIR/update_tests_from_public_list.py" ]]; then
    log "Config not found. Attempting to refresh public server list..."
    if python3 "$SCRIPT_DIR/update_tests_from_public_list.py" --count 8 --continent "North America" --min-gbps 10 --udp-bandwidth "10G" --out "$CONFIG_PATH" --cache-dir "$SCRIPT_DIR/data"; then
      log "Refreshed tests.json."
    fi
  fi
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  die "Config not found: $CONFIG_PATH"
fi

if [[ -z "$RUN_ID" ]]; then
  RUN_ID=$(default_run_id)
fi

ensure_out_dir "$OUT_BASE" "$RUN_ID"

log "Starting iperf3 tests using config: $CONFIG_PATH"
if [[ "$AUTO_REFRESH" == "1" && -x "$SCRIPT_DIR/update_tests_from_public_list.py" ]]; then
  log "AUTO_REFRESH=1, refreshing public server list before run..."
  if python3 "$SCRIPT_DIR/update_tests_from_public_list.py" --count 8 --continent "North America" --min-gbps 10 --udp-bandwidth "10G" --out "$CONFIG_PATH" --cache-dir "$SCRIPT_DIR/data"; then
    log "Refreshed tests.json from public list."
  else
    log "Refresh failed; proceeding with existing tests.json."
  fi
fi

while IFS= read -r test_json; do
  name=$(config_get "$test_json" '.name')
  server_host=$(config_get "$test_json" '.server_host')
  protocol=$(config_get "$test_json" '.protocol')
  direction=$(config_get "$test_json" '.direction')
  duration=$(config_get "$test_json" '.duration')
  parallel=$(config_get "$test_json" '.parallel_streams')
  iperf_port=$(config_get "$test_json" '.iperf_port')
  udp_bandwidth=$(config_get "$test_json" '.udp_bandwidth')
  start_server=$(config_get "$test_json" '.start_server')
  run_iperf=$(config_get "$test_json" '.run_iperf')
  run_timeout_sec=$(config_get "$test_json" '.run_timeout_sec')
  cooldown_sec=$(config_get "$test_json" '.cooldown_sec')
  runs_per_test=$(config_get "$test_json" '.runs_per_test')
  adaptive_udp=$(config_get "$test_json" '.adaptive_udp')
  udp_start_bps=$(config_get "$test_json" '.udp_start_bps')
  udp_step_bps=$(config_get "$test_json" '.udp_step_bps')
  udp_max_bps=$(config_get "$test_json" '.udp_max_bps')
  udp_loss_threshold=$(config_get "$test_json" '.udp_loss_threshold')
  udp_jitter_threshold=$(config_get "$test_json" '.udp_jitter_threshold')
  udp_drop_threshold=$(config_get "$test_json" '.udp_drop_threshold')

  ssh_user=$(config_get "$test_json" '.server_ssh_user')
  ssh_host=$(config_get "$test_json" '.server_ssh_host')
  ssh_port=$(config_get "$test_json" '.server_ssh_port')
  ssh_key=$(config_get "$test_json" '.server_ssh_key')
  ssh_opts=$(config_get "$test_json" '.server_ssh_opts')
  preflight_ping=$(config_get "$test_json" '.preflight_ping')
  ping_count=$(config_get "$test_json" '.ping_count')

  notes=$(config_get "$test_json" '.notes')
  site=$(config_get "$test_json" '.site')
  country=$(config_get "$test_json" '.country')
  continent=$(config_get "$test_json" '.continent')
  provider=$(config_get "$test_json" '.provider')
  gbps=$(config_get "$test_json" '.gbps')
  port_range=$(config_get "$test_json" '.port_range')

  if [[ -z "$name" || -z "$server_host" ]]; then
    log "Skipping test with missing name or server_host."
    continue
  fi

  if [[ "$run_iperf" != "true" ]]; then
    log "[$name] run_iperf=false; skipping iperf tests."
    continue
  fi

  if [[ -z "$protocol" ]]; then protocol="tcp"; fi
  if [[ -z "$direction" ]]; then direction="uplink"; fi
  if [[ -z "$duration" ]]; then duration="10"; fi
  if [[ -z "$parallel" ]]; then parallel="1"; fi
  if [[ -z "$iperf_port" ]]; then iperf_port="5201"; fi
  if [[ -z "$udp_bandwidth" ]]; then udp_bandwidth="0"; fi
  if [[ -z "$start_server" ]]; then start_server="true"; fi
  if [[ -z "$preflight_ping" ]]; then preflight_ping="true"; fi
  if [[ -z "$ping_count" ]]; then ping_count="5"; fi
  if [[ -z "$cooldown_sec" ]]; then cooldown_sec="5"; fi
  if [[ -z "$run_timeout_sec" ]]; then run_timeout_sec="$((duration + 20))"; fi
  if [[ -z "$runs_per_test" ]]; then runs_per_test="1"; fi
  if [[ -z "$adaptive_udp" ]]; then adaptive_udp="false"; fi
  if [[ -z "$udp_start_bps" ]]; then udp_start_bps="1G"; fi
  if [[ -z "$udp_step_bps" ]]; then udp_step_bps="1G"; fi
  if [[ -z "$udp_max_bps" ]]; then udp_max_bps="10G"; fi
  if [[ -z "$udp_loss_threshold" ]]; then udp_loss_threshold="1.0"; fi
  if [[ -z "$udp_jitter_threshold" ]]; then udp_jitter_threshold="5.0"; fi
  if [[ -z "$udp_drop_threshold" ]]; then udp_drop_threshold="5.0"; fi

  rtt_avg=""
  ttl_avg=""
  preflight_loss=""
  if [[ "$preflight_ping" == "true" ]]; then
    if ping -c "$ping_count" -w 5 "$server_host" >/tmp/onslawt_ping.$$ 2>/dev/null; then
      rtt_line=$(grep -E 'min/avg/max' /tmp/onslawt_ping.$$ | tail -n 1 || true)
      rtt_avg=$(echo "$rtt_line" | awk -F'=' '{print $2}' | awk -F'/' '{print $2}' | awk '{print $1}')
      ttl_avg=$(grep -o 'ttl=[0-9]*' /tmp/onslawt_ping.$$ | cut -d= -f2 | awk '{sum+=$1; n++} END{if(n>0) printf "%.1f", sum/n; else print ""}')
      loss_line=$(grep -E 'packet loss' /tmp/onslawt_ping.$$ | tail -n 1 || true)
      preflight_loss=$(echo "$loss_line" | sed -n 's/.*\\([0-9.]*\\)% packet loss.*/\\1/p')
    fi
    rm -f /tmp/onslawt_ping.$$
    if [[ -n "$rtt_avg" ]]; then
      log "[$name] Preflight RTT avg ms: $rtt_avg"
    else
      log "[$name] Preflight RTT avg ms: n/a"
    fi
    if [[ -n "$ttl_avg" ]]; then
      log "[$name] Preflight TTL avg: $ttl_avg"
    fi
    if [[ -n "$preflight_loss" ]]; then
      log "[$name] Preflight loss %: $preflight_loss"
    fi
  fi

  # Only attempt SSH start if SSH info is explicitly provided (ignore default port alone).
  if [[ -n "$ssh_user" || -n "$ssh_host" || -n "$ssh_key" || -n "$ssh_opts" ]]; then
    if [[ -z "$ssh_user" ]]; then ssh_user="$USER"; fi
    if [[ -z "$ssh_host" ]]; then ssh_host="$server_host"; fi
  else
    ssh_user=""
    ssh_host=""
  fi

  maybe_start_iperf_server "$name" "$server_host" "$iperf_port" "$start_server" \
    "$ssh_user" "$ssh_host" "$ssh_port" "$ssh_key" "$ssh_opts"

  run_one() {
    local run_direction="$1"
    local run_index="$2"
    local ts
    ts=$(date -Iseconds)

    local suffix=""
    if [[ -n "$run_index" && "$run_index" -gt 1 ]]; then
      suffix="_run${run_index}"
    fi
    local outfile="$OUT_DIR/iperf_${name}_${run_direction}${suffix}.json"
    local rawfile="$OUT_DIR/iperf_${name}_${run_direction}${suffix}.raw.json"
    local errfile="$OUT_DIR/iperf_${name}_${run_direction}${suffix}.stderr.log"

    # Adaptive UDP ramp: steadily increase until pushback, then stop.
    if [[ "$protocol" == "udp" && "$adaptive_udp" == "true" ]]; then
      if [[ "$run_index" -gt 1 ]]; then
        log "[$name] Adaptive UDP already ran; skipping additional run_index=$run_index."
        return 0
      fi
      local out_adapt="$OUT_DIR/adaptive_udp_${name}_${run_direction}.json"
      local meta_json
      meta_json=$(jq -n \
        --arg name "$name" \
        --arg server_host "$server_host" \
        --arg site "$site" \
        --arg country "$country" \
        --arg continent "$continent" \
        --arg provider "$provider" \
        --arg gbps "$gbps" \
        --arg port_range "$port_range" \
        --arg rtt_avg_ms "$rtt_avg" \
        '{name:$name, server_host:$server_host, site:$site, country:$country, continent:$continent, provider:$provider, gbps:($gbps|tonumber?), port_range:$port_range, rtt_avg_ms: ($rtt_avg_ms|tonumber?)}')

      log "[$name] Adaptive UDP ramp ${run_direction}: start=${udp_start_bps}, step=${udp_step_bps}, max=${udp_max_bps}."
      if ! python3 "$SCRIPT_DIR/adaptive_udp.py" \
        --server "$server_host" \
        --port "$iperf_port" \
        --direction "$run_direction" \
        --duration "$duration" \
        --parallel "$parallel" \
        --start "$udp_start_bps" \
        --step "$udp_step_bps" \
        --max "$udp_max_bps" \
        --loss-threshold "$udp_loss_threshold" \
        --jitter-threshold "$udp_jitter_threshold" \
        --drop-threshold "$udp_drop_threshold" \
        --timeout "$run_timeout_sec" \
        --out "$out_adapt" \
        --meta "$meta_json"; then
        log "[$name] Adaptive UDP ramp failed."
        return 1
      fi
      log "[$name] Saved adaptive UDP results to $out_adapt"
      return 0
    fi

    local cmd=(iperf3 -c "$server_host" -p "$iperf_port" -t "$duration" -P "$parallel" -J)

    if [[ "$protocol" == "udp" ]]; then
      cmd+=( -u -b "$udp_bandwidth" )
    fi

    if [[ "$run_direction" == "downlink" ]]; then
      cmd+=( -R )
    fi

    log "[$name] Running iperf3 ${protocol} ${run_direction} for ${duration}s (P=${parallel})."
    log "[$name] Command: ${cmd[*]}"
    local timeout_cmd=()
    if command -v timeout >/dev/null 2>&1; then
      timeout_cmd=(timeout "${run_timeout_sec}")
    fi

    if ! "${timeout_cmd[@]}" "${cmd[@]}" >"$rawfile" 2>"$errfile"; then
      local exit_code=$?
      if [[ "$exit_code" -eq 124 ]]; then
        log "[$name] iperf3 command timed out after ${run_timeout_sec}s. stdout=$rawfile stderr=$errfile"
      else
        log "[$name] iperf3 command failed (exit $exit_code). stdout=$rawfile stderr=$errfile"
      fi

      # Write a minimal result so reports can include failures.
      local ts_fail
      ts_fail=$(date -Iseconds)
      local meta_fail
      meta_fail=$(jq -n \
        --arg name "$name" \
        --arg tool "iperf3" \
        --arg protocol "$protocol" \
        --arg direction "$run_direction" \
        --arg timestamp "$ts_fail" \
        --arg server_host "$server_host" \
        --arg duration "$duration" \
        --arg parallel_streams "$parallel" \
        --arg iperf_port "$iperf_port" \
        --arg notes "$notes" \
        --arg site "$site" \
        --arg country "$country" \
        --arg continent "$continent" \
        --arg provider "$provider" \
        --arg gbps "$gbps" \
        --arg port_range "$port_range" \
        --arg rtt_avg_ms "$rtt_avg" \
        --arg run_index "$run_index" \
        --arg raw_json_valid "false" \
        --arg error "iperf_failed" \
        '{name:$name, tool:$tool, protocol:$protocol, direction:$direction, timestamp:$timestamp,
          server_host:$server_host, duration:$duration|tonumber, parallel_streams:$parallel_streams|tonumber, iperf_port:$iperf_port|tonumber,
          notes:$notes, site:$site, country:$country, continent:$continent, provider:$provider, gbps:($gbps|tonumber?), port_range:$port_range,
          rtt_avg_ms: ($rtt_avg_ms|tonumber?), run_index: ($run_index|tonumber?), raw_json_valid: false, error:$error }')
      jq -n --arg meta "$meta_fail" '{meta: ($meta|fromjson?), summary:{}, raw:""}' > "$outfile"
      return 1
    fi

    # Clean CR characters that can break jq parsing on some systems.
    local cleanfile="$OUT_DIR/iperf_${name}_${run_direction}.raw.clean.json"
    tr -d '\r' < "$rawfile" > "$cleanfile" || true

    local parse_file="$rawfile"
    if [[ -s "$cleanfile" ]]; then
      parse_file="$cleanfile"
    fi

    local raw_json_valid="true"
    if ! jq -e . "$parse_file" >/dev/null 2>&1; then
      raw_json_valid="false"
    fi
    if [[ "$raw_json_valid" != "true" ]]; then
      log "[$name] iperf3 output was not valid JSON; raw output saved."
    fi

    local summary
    if [[ "$raw_json_valid" == "true" ]]; then
      summary=$(jq -c --arg proto "$protocol" '
      def tcp: {
        tcp_sent_bps: (.end.sum_sent.bits_per_second // null),
        tcp_recv_bps: (.end.sum_received.bits_per_second // null),
        tcp_retransmits: (.end.sum_sent.retransmits // null)
      };
      def udp: {
        udp_bps: (.end.sum.bits_per_second // .end.sum_received.bits_per_second // null),
        udp_jitter_ms: (.end.sum.jitter_ms // .end.sum_received.jitter_ms // null),
        udp_lost_percent: (.end.sum.lost_percent // .end.sum_received.lost_percent // null),
        udp_packets: (.end.sum.packets // .end.sum_received.packets // null)
      };
      if $proto=="udp" then udp else tcp end
      ' "$parse_file")
    else
      summary=$(jq -n '{}')
    fi

    local meta
    meta=$(jq -n \
      --arg name "$name" \
      --arg tool "iperf3" \
      --arg protocol "$protocol" \
      --arg direction "$run_direction" \
      --arg timestamp "$ts" \
      --arg server_host "$server_host" \
      --arg duration "$duration" \
      --arg parallel_streams "$parallel" \
      --arg iperf_port "$iperf_port" \
      --arg notes "$notes" \
      --arg site "$site" \
      --arg country "$country" \
      --arg continent "$continent" \
      --arg provider "$provider" \
      --arg gbps "$gbps" \
      --arg port_range "$port_range" \
      --arg rtt_avg_ms "$rtt_avg" \
      --arg run_index "$run_index" \
      --arg ttl_avg "$ttl_avg" \
      --arg preflight_loss "$preflight_loss" \
      --arg raw_json_valid "$raw_json_valid" \
      '{name:$name, tool:$tool, protocol:$protocol, direction:$direction, timestamp:$timestamp,
        server_host:$server_host, duration:$duration|tonumber, parallel_streams:$parallel_streams|tonumber, iperf_port:$iperf_port|tonumber,
        notes:$notes, site:$site, country:$country, continent:$continent, provider:$provider, gbps:($gbps|tonumber?), port_range:$port_range,
        rtt_avg_ms: ($rtt_avg_ms|tonumber?), ttl_avg: ($ttl_avg|tonumber?), preflight_loss: ($preflight_loss|tonumber?), run_index: ($run_index|tonumber?), raw_json_valid: ($raw_json_valid=="true") }')

    if [[ "$raw_json_valid" == "true" ]]; then
      jq -n --arg meta "$meta" --arg summary "$summary" --slurpfile result "$parse_file" \
        '{meta: ($meta|fromjson?), summary: ($summary|fromjson?), result:$result[0]}' > "$outfile"
    else
      log "[$name] iperf3 JSON parse failed; saving raw output as text."
      raw_text=$(cat "$rawfile")
      jq -n --arg meta "$meta" --arg summary "$summary" --arg raw "$raw_text" \
        '{meta: ($meta|fromjson?), summary: ($summary|fromjson?), raw:$raw}' > "$outfile"
    fi

    rm -f "$cleanfile"

    log "[$name] Saved iperf3 results to $outfile"
  }

  case "$direction" in
    uplink)
      for ((i=1; i<=runs_per_test; i++)); do
        run_one "uplink" "$i" || true
        sleep "$cooldown_sec"
      done
      ;;
    downlink)
      for ((i=1; i<=runs_per_test; i++)); do
        run_one "downlink" "$i" || true
        sleep "$cooldown_sec"
      done
      ;;
    bidirectional)
      for ((i=1; i<=runs_per_test; i++)); do
        run_one "uplink" "$i" || true
        sleep "$cooldown_sec"
        run_one "downlink" "$i" || true
        sleep "$cooldown_sec"
      done
      ;;
    *)
      log "[$name] Unknown direction '$direction'; defaulting to uplink."
      for ((i=1; i<=runs_per_test; i++)); do
        run_one "uplink" "$i" || true
        sleep "$cooldown_sec"
      done
      ;;
  esac

  log "[$name] Completed iperf3 tests."

done < <(config_get_tests "$CONFIG_PATH" "$ONLY_TEST")

log "iperf3 test run complete."
