# ONSLAWT
Operational Network Speed & Latency Analyzer for WAN and LAN Testing

ONSLAWT is a Bash/Python toolkit for capturing baseline and post-upgrade network performance across WAN/LAN links. It measures throughput (and optionally latency, jitter, packet loss, MTU, and hop-by-hop behavior) and stores structured outputs for comparisons.

## What You Get
- `iperf3` TCP/UDP throughput and UDP jitter/packet loss
- ICMP latency bursts (min/avg/max + loss)
- `mtr` hop-by-hop reports
- MTU discovery via `tracepath` (or `ping -M do` fallback)
- Optional Internet speedtest
- Python comparison tool for pre/post datasets

## Quick Start
1. Install dependencies on the jump host:
   ```bash
   /Users/dan.driver/Cursor_projects/bash/ONSLAWT/setup_env.sh
   ```

2. Edit `/Users/dan.driver/Cursor_projects/bash/ONSLAWT/tests.json` with your WAN iperf3 servers (or internal endpoints if you re-enable LAN tests).

3. Run the full suite:
   ```bash
   /Users/dan.driver/Cursor_projects/bash/ONSLAWT/run_all.sh
   ```

4. Compare baseline vs post-upgrade:
   ```bash
   python3 /Users/dan.driver/Cursor_projects/bash/ONSLAWT/analyze_results.py \
     --baseline /Users/dan.driver/Cursor_projects/bash/ONSLAWT/results/20240206_090000 \
     --post /Users/dan.driver/Cursor_projects/bash/ONSLAWT/results/20240207_090000 \
     --out /Users/dan.driver/Cursor_projects/bash/ONSLAWT/results/compare.md
   ```

## Configuration (`tests.json`)
Each test inherits `defaults` and can override any field. Key fields:
- `name` (required)
- `client_host` (informational)
- `server_host` (required for iperf/latency/mtr/mtu)
- `protocol`: `tcp` or `udp`
- `direction`: `uplink`, `downlink`, `bidirectional`
- `duration`: seconds
- `parallel_streams`: iperf `-P`
- `udp_bandwidth`: iperf `-b` (e.g., `1G`). Default `0` (unlimited).
- `start_server`: start iperf3 server via SSH if SSH info provided
- `server_ssh_user`, `server_ssh_host`, `server_ssh_port`, `server_ssh_key`, `server_ssh_opts`
- `run_iperf`, `run_latency`, `run_mtr`, `run_mtu`, `run_speedtest`
- `ping_count`, `ping_interval_ms`, `ping_pause_ms`, `ping_bursts`
- `mtr_cycles`
- `mtu_test`, `mtu_max_size`, `mtu_min_size`
- `type`: set to `speedtest` for WAN speed tests (or use `run_speedtest=true`)

### SSH notes
ONSLAWT only attempts to start `iperf3 -s` via SSH when you provide SSH fields in the test or defaults. If you omit SSH settings, it assumes the server is already running, or uses a local server when `server_host` is `localhost`/`127.0.0.1`.

### WAN-only defaults
The current `tests.json` is set up for WAN-only iperf3 testing with 10G+ public servers. Latency/mtr/MTU/speedtest are disabled by default for a simpler throughput-focused run. You can re-enable those per test if desired.

## Scripts
- `/Users/dan.driver/Cursor_projects/bash/ONSLAWT/setup_env.sh` – dependency installer
- `/Users/dan.driver/Cursor_projects/bash/ONSLAWT/run_all.sh` – full suite runner
- `/Users/dan.driver/Cursor_projects/bash/ONSLAWT/run_iperf_tests.sh`
- `/Users/dan.driver/Cursor_projects/bash/ONSLAWT/run_latency_tests.sh`
- `/Users/dan.driver/Cursor_projects/bash/ONSLAWT/run_mtr.sh`
- `/Users/dan.driver/Cursor_projects/bash/ONSLAWT/run_mtu_tests.sh`
- `/Users/dan.driver/Cursor_projects/bash/ONSLAWT/run_speedtest.sh`
- `/Users/dan.driver/Cursor_projects/bash/ONSLAWT/analyze_results.py`

## Output Layout
Results are stored under `results/<run_id>/`:
- `iperf_<name>_<direction>.json`
- `latency_<name>.json`
- `mtr_<name>.json`
- `mtu_<name>.json`
- `speedtest_<name>.json`
- `run.log`
 - `iperf_<name>_<direction>.stderr.log` (only if iperf emits errors)

## Operational Notes
- ICMP bursts are short by default (`20` packets at `2ms` intervals) to reduce IDS/IPS false positives. Adjust `ping_interval_ms` and `ping_bursts` as needed.
- For UDP tests, set `udp_bandwidth` per path to avoid saturating links unintentionally.
- Always run baseline tests at consistent times (e.g., peak and off-peak) for better comparisons.

## Next Steps
- Populate `tests.json` with your IronBird/HQ4 endpoints, VPN targets, and WAN IPs.
- Run baseline tests before the firewall cutover, then re-run after installing the Meraki MX450.
- Use `analyze_results.py` to quantify improvements and regressions.
