#!/usr/bin/env python3
import argparse
import csv
import json
import os
import re
import sys
import time
import subprocess
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional
from urllib.request import Request, urlopen

CSV_URL = "https://export.iperf3serverlist.net/listed_iperf3_servers.csv"
JSON_URL = "https://export.iperf3serverlist.net/listed_iperf3_servers.json"


def fetch(url: str) -> Optional[bytes]:
    try:
        req = Request(url, headers={"User-Agent": "ONSLAWT/1.0"})
        with urlopen(req, timeout=20) as resp:
            return resp.read()
    except Exception:
        return None


def parse_gbps(value: str) -> Optional[float]:
    if not value:
        return None
    s = value.strip().lower()
    # handle formats like "2x10"
    if "x" in s:
        parts = [p for p in re.split(r"x", s) if p]
        try:
            nums = [float(p) for p in parts]
            if len(nums) == 2:
                return nums[0] * nums[1]
        except Exception:
            pass
    # fall back to first number
    m = re.search(r"\d+(?:\.\d+)?", s)
    if m:
        try:
            return float(m.group(0))
        except Exception:
            return None
    return None


def parse_port(port_str: str) -> str:
    if not port_str:
        return ""
    s = port_str.strip()
    for part in s.replace(" ", "").split(","):
        if "-" in part:
            return part.split("-")[0]
        if part.isdigit():
            return part
    m = re.search(r"\d+", s)
    return m.group(0) if m else ""


def get_value(rec: Dict[str, Any], keys: List[str]) -> str:
    # direct match
    for k in keys:
        if k in rec and rec[k] not in (None, ""):
            return str(rec[k])
    # case-insensitive match
    lower_map = {k.lower(): k for k in rec.keys()}
    for k in keys:
        key = lower_map.get(k.lower())
        if key and rec[key] not in (None, ""):
            return str(rec[key])
    return ""


def normalize_record(rec: Dict[str, Any]) -> Dict[str, Any]:
    host = get_value(rec, ["IP/HOST", "ip_host", "host", "ip", "hostname"]).strip()
    port = get_value(rec, ["PORT", "port"]).strip()
    gbps_str = get_value(rec, ["GB/S", "gbps", "gb_s", "speed"]).strip()
    continent = get_value(rec, ["CONTINENT", "continent"]).strip()
    country = get_value(rec, ["COUNTRY", "country", "country_code"]).strip()
    site = get_value(rec, ["SITE", "site", "city"]).strip()
    provider = get_value(rec, ["PROVIDER", "provider", "isp"]).strip()

    return {
        "host": host,
        "port_range": port,
        "port": parse_port(port),
        "gbps_str": gbps_str,
        "gbps": parse_gbps(gbps_str),
        "continent": continent,
        "country": country,
        "site": site,
        "provider": provider,
    }


def load_records_from_json(data: bytes) -> List[Dict[str, Any]]:
    try:
        obj = json.loads(data.decode("utf-8"))
    except Exception:
        return []

    # json may be a list or wrapped in an object
    if isinstance(obj, dict):
        for v in obj.values():
            if isinstance(v, list):
                obj = v
                break

    if not isinstance(obj, list):
        return []

    return [normalize_record(r) for r in obj if isinstance(r, dict)]


def load_records_from_csv(data: bytes) -> List[Dict[str, Any]]:
    try:
        text = data.decode("utf-8", errors="ignore")
    except Exception:
        return []
    reader = csv.DictReader(text.splitlines())
    return [normalize_record(r) for r in reader]


def select_diverse(records: List[Dict[str, Any]], count: int) -> List[Dict[str, Any]]:
    selected: List[Dict[str, Any]] = []
    used_site = set()
    used_provider = set()
    used_country = set()

    remaining = records[:]
    while remaining and len(selected) < count:
        best = None
        best_score = -1
        for r in remaining:
            score = 0
            if r.get("country") and r["country"] not in used_country:
                score += 3
            if r.get("site") and r["site"] not in used_site:
                score += 2
            if r.get("provider") and r["provider"] not in used_provider:
                score += 1
            if score > best_score:
                best = r
                best_score = score
            elif score == best_score and best is not None:
                if (r.get("gbps") or 0) > (best.get("gbps") or 0):
                    best = r
        if best is None:
            break
        selected.append(best)
        used_site.add(best.get("site"))
        used_provider.add(best.get("provider"))
        used_country.add(best.get("country"))
        remaining = [r for r in remaining if r != best]

    if len(selected) < count:
        for r in records:
            if r not in selected:
                selected.append(r)
            if len(selected) >= count:
                break

    return selected


def verify_server(host: str, port: int, timeout_sec: int, duration: int) -> bool:
    cmd = [
        "iperf3",
        "-c", host,
        "-p", str(port),
        "-t", str(duration),
        "-P", "1",
        "-J",
    ]
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout_sec, check=False)
    except Exception:
        return False
    if res.returncode != 0:
        return False
    try:
        data = json.loads(res.stdout.decode("utf-8", errors="ignore"))
    except Exception:
        return False
    end = data.get("end", {})
    sum_sent = end.get("sum_sent", {}) or {}
    sum_recv = end.get("sum_received", {}) or {}
    return ("bits_per_second" in sum_sent) or ("bits_per_second" in sum_recv)


def slugify(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")


def build_tests(selected: List[Dict[str, Any]], udp_bandwidth: str) -> List[Dict[str, Any]]:
    tests = []
    for r in selected:
        host = r["host"]
        port = int(r["port"]) if r.get("port") else 5201
        base_name = slugify("_".join(filter(None, [r.get("country"), r.get("site"), r.get("provider"), host])))
        if not base_name:
            base_name = slugify(host) or "iperf"

        common = {
            "server_host": host,
            "iperf_port": port,
            "continent": r.get("continent", ""),
            "country": r.get("country", ""),
            "site": r.get("site", ""),
            "provider": r.get("provider", ""),
            "gbps": r.get("gbps"),
            "port_range": r.get("port_range", ""),
            "notes": f"{r.get('provider','')} | {r.get('site','')} {r.get('country','')} | {r.get('gbps_str','')} Gbps | ports {r.get('port_range','')}".strip(),
        }

        tests.append({
            "name": f"wan_{base_name}_tcp",
            "protocol": "tcp",
            **common,
        })
        tests.append({
            "name": f"wan_{base_name}_udp",
            "protocol": "udp",
            "udp_bandwidth": udp_bandwidth,
            **common,
        })

    return tests


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate tests.json from public iperf3 server list")
    parser.add_argument("--count", type=int, default=8, help="Number of distinct servers to include")
    parser.add_argument("--continent", default="North America", help="Continent filter")
    parser.add_argument("--min-gbps", type=float, default=10.0, help="Minimum server capacity (Gbps)")
    parser.add_argument("--udp-bandwidth", default="10G", help="UDP bandwidth to use")
    parser.add_argument("--out", default="tests.json", help="Output tests.json path")
    parser.add_argument("--cache-dir", default="data", help="Directory to store downloaded lists")
    parser.add_argument("--verify", action="store_true", help="Verify servers with a quick iperf3 check")
    parser.add_argument("--verify-timeout", type=int, default=8, help="Verification timeout seconds")
    parser.add_argument("--verify-duration", type=int, default=2, help="Verification test duration seconds")
    args = parser.parse_args()

    os.makedirs(args.cache_dir, exist_ok=True)

    json_data = fetch(JSON_URL)
    csv_data = fetch(CSV_URL)

    if json_data:
        with open(os.path.join(args.cache_dir, "listed_iperf3_servers.json"), "wb") as f:
            f.write(json_data)
    if csv_data:
        with open(os.path.join(args.cache_dir, "listed_iperf3_servers.csv"), "wb") as f:
            f.write(csv_data)

    records = []
    if json_data:
        records = load_records_from_json(json_data)
    if not records and csv_data:
        records = load_records_from_csv(csv_data)

    if not records:
        print("Failed to load server list.", file=sys.stderr)
        return 1

    # filter by continent and capacity
    continent = args.continent.strip().lower()
    filtered = []
    for r in records:
        c = (r.get("continent") or "").strip().lower()
        gbps = r.get("gbps")
        if c == continent and gbps is not None and gbps >= args.min_gbps and r.get("host"):
            filtered.append(r)

    # de-duplicate by host
    seen = set()
    deduped = []
    for r in filtered:
        key = (r.get("host"), r.get("port_range"))
        if key in seen:
            continue
        seen.add(key)
        deduped.append(r)

    if not deduped:
        print("No matching servers found after filtering.", file=sys.stderr)
        return 1

    selected = select_diverse(deduped, args.count)

    if args.verify:
        verified = []
        for r in deduped:
            if len(verified) >= args.count:
                break
            host = r.get("host")
            port = int(r.get("port") or 5201)
            if verify_server(host, port, args.verify_timeout, args.verify_duration):
                verified.append(r)
        if verified:
            selected = select_diverse(verified, args.count)

    tests = build_tests(selected, args.udp_bandwidth)

    output = {
        "meta": {
            "source_json": JSON_URL,
            "source_csv": CSV_URL,
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "criteria": {
                "continent": args.continent,
                "min_gbps": args.min_gbps,
                "count": args.count,
                "udp_bandwidth": args.udp_bandwidth,
            },
        },
        "defaults": {
            "protocol": "tcp",
            "direction": "bidirectional",
            "duration": 15,
            "parallel_streams": 4,
            "iperf_port": 5201,
            "udp_bandwidth": args.udp_bandwidth,
            "start_server": False,
            "run_iperf": True,
            "run_latency": False,
            "run_mtr": False,
            "run_mtu": False,
            "run_speedtest": False,
            "preflight_ping": True,
            "runs_per_test": 2,
            "ping_count": 5,
            "ping_interval_ms": 200,
            "ping_pause_ms": 200,
            "ping_bursts": 1,
            "cooldown_sec": 3,
            "run_timeout_sec": 45,
            "adaptive_udp": True,
            "udp_start_bps": "2G",
            "udp_step_bps": "2G",
            "udp_max_bps": "10G",
            "udp_loss_threshold": 1.0,
            "udp_jitter_threshold": 5.0,
            "udp_drop_threshold": 5.0,
            "mtr_cycles": 10,
            "mtu_test": False,
            "mtu_max_size": 1472,
            "mtu_min_size": 1200,
            "server_ssh_user": "",
            "server_ssh_host": "",
            "server_ssh_port": 22,
            "server_ssh_key": "",
            "server_ssh_opts": ""
        },
        "tests": tests,
    }

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
