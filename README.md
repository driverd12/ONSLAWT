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
   ./setup_env.sh
   ```
   If your system blocks `pip` installs (PEP 668), that's OK — `speedtest-cli` is optional for WAN throughput. The rest of the suite will work without it.

2. Refresh the public iperf3 list (North America, 10G+, 8 diverse servers):
   ```bash
   ./refresh_public_tests.sh
   ```
   This pulls the latest CSV/JSON list, verifies servers with a quick iperf3 check, and regenerates `tests.json`.

3. Run the full suite:
   ```bash
   ./run_all.sh
   ```

3a. WAN-only guided run (prompts for Palo vs MX450, generates report + graphs):
   ```bash
   ./run_wan_suite.sh
   ```
   This uses a lower, firewall-friendly load profile by default (15s, P=4) and enforces per-test timeouts plus cooldowns.
   UDP tests are adaptive: they ramp up toward 10G and fall back when quality degrades.
   Reports are generated as both `report.md` and `report.html` with SVG charts.
   The runner repeats each test once by default for quick runs (`runs_per_test: 1`) to reduce runtime.
   Use `PROFILE=high` for a more aggressive/high-end run with adaptive UDP ramp:
   ```bash
   PROFILE=high ./run_wan_suite.sh
   ```
   To run endpoints in parallel (faster), set `PARALLEL_JOBS` (default 1):
   ```bash
   PARALLEL_JOBS=2 ./run_wan_suite.sh
   ```

4. Compare baseline vs post-upgrade:
   ```bash
   python3 ./analyze_results.py \
     --baseline ./results/20240206_090000 \
     --post ./results/20240207_090000 \
     --out ./results/compare.md
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
The default run also performs a short preflight `ping` to record average RTT in each iperf result (as a distance indicator).

## Scripts
- `./setup_env.sh` – dependency installer
- `./run_all.sh` – full suite runner
- `./run_iperf_tests.sh`
- `./run_iperf_parallel.sh` – parallel runner across endpoints (uses `PARALLEL_JOBS`)
- `./run_wan_suite.sh` – guided WAN run, prompts for device and generates report
- `./report_results.py` – builds stats + graphs from a run directory
- `./refresh_public_tests.sh` – refreshes `tests.json` from the public iperf server list
- `./update_tests_from_public_list.py` – pulls CSV/JSON list and selects 8 diverse NA servers (10G+)
- `./run_latency_tests.sh`
- `./run_mtr.sh`
- `./run_mtu_tests.sh`
- `./run_speedtest.sh`
- `./analyze_results.py`

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
- Populate `tests.json` with the WAN iperf3 targets you want to baseline.
- Run baseline tests before the firewall cutover, then re-run after installing the Meraki MX450 using the same test list.
- Use `analyze_results.py` to quantify improvements and regressions.
