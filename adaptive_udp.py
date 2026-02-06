#!/usr/bin/env python3
import argparse
import json
import math
import subprocess
import time
from datetime import datetime, timezone
from typing import Dict, Any, Optional


def parse_bps(value: str) -> Optional[float]:
    if value is None:
        return None
    s = str(value).strip().lower()
    if s == "":
        return None
    mult = 1.0
    if s.endswith("k"):
        mult = 1e3
        s = s[:-1]
    elif s.endswith("m"):
        mult = 1e6
        s = s[:-1]
    elif s.endswith("g"):
        mult = 1e9
        s = s[:-1]
    elif s.endswith("t"):
        mult = 1e12
        s = s[:-1]
    try:
        return float(s) * mult
    except Exception:
        return None


def bps_to_str(bps: float) -> str:
    if bps >= 1e9:
        return f"{bps/1e9:.3f}G"
    if bps >= 1e6:
        return f"{bps/1e6:.3f}M"
    if bps >= 1e3:
        return f"{bps/1e3:.3f}K"
    return f"{bps:.0f}"


def run_iperf(server: str, port: int, direction: str, duration: int, parallel: int, bandwidth: str, timeout_sec: int) -> Dict[str, Any]:
    cmd = [
        "iperf3", "-c", server, "-p", str(port), "-t", str(duration), "-P", str(parallel), "-J", "-u", "-b", bandwidth
    ]
    if direction == "downlink":
        cmd.append("-R")

    try:
        completed = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout_sec, check=False)
    except subprocess.TimeoutExpired:
        return {"error": "timeout", "cmd": " ".join(cmd)}

    if completed.returncode != 0:
        return {"error": f"exit_{completed.returncode}", "stderr": completed.stderr.decode("utf-8", errors="ignore"), "cmd": " ".join(cmd)}

    try:
        data = json.loads(completed.stdout.decode("utf-8", errors="ignore"))
    except Exception:
        return {"error": "json_parse", "stdout": completed.stdout.decode("utf-8", errors="ignore"), "cmd": " ".join(cmd)}

    return {"data": data, "cmd": " ".join(cmd)}


def extract_udp_stats(data: Dict[str, Any]) -> Dict[str, Any]:
    end = data.get("end", {})
    sum_ = end.get("sum", {}) or end.get("sum_received", {}) or {}
    return {
        "throughput_bps": sum_.get("bits_per_second"),
        "jitter_ms": sum_.get("jitter_ms"),
        "loss_percent": sum_.get("lost_percent"),
        "packets": sum_.get("packets"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Adaptive UDP ramp test")
    parser.add_argument("--server", required=True)
    parser.add_argument("--port", type=int, default=5201)
    parser.add_argument("--direction", choices=["uplink", "downlink"], required=True)
    parser.add_argument("--duration", type=int, default=15)
    parser.add_argument("--parallel", type=int, default=4)
    parser.add_argument("--start", required=True)
    parser.add_argument("--step", required=True)
    parser.add_argument("--max", dest="max_bps", required=True)
    parser.add_argument("--loss-threshold", type=float, default=1.0)
    parser.add_argument("--jitter-threshold", type=float, default=5.0)
    parser.add_argument("--drop-threshold", type=float, default=5.0)
    parser.add_argument("--timeout", type=int, default=45)
    parser.add_argument("--out", required=True)
    parser.add_argument("--meta", default="{}")
    args = parser.parse_args()

    start_bps = parse_bps(args.start)
    step_bps = parse_bps(args.step)
    max_bps = parse_bps(args.max_bps)
    if start_bps is None or step_bps is None or max_bps is None:
        raise SystemExit("Invalid bandwidth values")

    try:
        meta = json.loads(args.meta)
    except Exception:
        meta = {}

    steps = []
    last_ok = None
    stop_reason = "max_reached"
    prev_throughput = None
    fallback_attempted = False

    current = start_bps
    while current <= max_bps + 1:
        bw_str = bps_to_str(current)
        result = run_iperf(args.server, args.port, args.direction, args.duration, args.parallel, bw_str, args.timeout)
        step = {
            "target_bps": current,
            "target_str": bw_str,
            "ok": False,
        }

        if "error" in result:
            step["error"] = result["error"]
            step["cmd"] = result.get("cmd")
            step["stderr"] = result.get("stderr")
            steps.append(step)
            stop_reason = result["error"]
            break

        stats = extract_udp_stats(result["data"])
        step.update(stats)
        step["cmd"] = result.get("cmd")

        loss = stats.get("loss_percent")
        jitter = stats.get("jitter_ms")
        throughput = stats.get("throughput_bps")

        ok = True
        if loss is not None and loss > args.loss_threshold:
            ok = False
            stop_reason = "loss_threshold"
        if jitter is not None and jitter > args.jitter_threshold:
            ok = False
            stop_reason = "jitter_threshold"
        if prev_throughput is not None and throughput is not None:
            if throughput < prev_throughput * (1 - args.drop_threshold / 100.0):
                ok = False
                stop_reason = "throughput_drop"

        step["ok"] = ok
        steps.append(step)

        if ok:
            last_ok = step
            prev_throughput = throughput if throughput is not None else prev_throughput
            current += step_bps
        else:
            # Fallback: re-test at last_ok (or step down if last_ok is not stable)
            if last_ok is None:
                break

            if not fallback_attempted:
                fallback_attempted = True

                # Confirm last_ok
                bw_str = bps_to_str(last_ok["target_bps"])
                confirm = run_iperf(args.server, args.port, args.direction, args.duration, args.parallel, bw_str, args.timeout)
                confirm_step = {
                    "target_bps": last_ok["target_bps"],
                    "target_str": bw_str,
                    "ok": False,
                    "confirm": True,
                }

                if "error" not in confirm:
                    stats = extract_udp_stats(confirm["data"])
                    confirm_step.update(stats)
                    confirm_step["cmd"] = confirm.get("cmd")

                    loss = stats.get("loss_percent")
                    jitter = stats.get("jitter_ms")
                    throughput = stats.get("throughput_bps")
                    ok_confirm = True
                    if loss is not None and loss > args.loss_threshold:
                        ok_confirm = False
                    if jitter is not None and jitter > args.jitter_threshold:
                        ok_confirm = False
                    if throughput is not None and prev_throughput is not None:
                        if throughput < prev_throughput * (1 - args.drop_threshold / 100.0):
                            ok_confirm = False
                    confirm_step["ok"] = ok_confirm

                    steps.append(confirm_step)
                    if ok_confirm:
                        last_ok = confirm_step
                        stop_reason = f"{stop_reason}_fallback_confirmed"
                        break

                # Step down once if confirm failed
                down = max(start_bps, last_ok["target_bps"] - step_bps)
                if down < last_ok["target_bps"]:
                    bw_str = bps_to_str(down)
                    retry = run_iperf(args.server, args.port, args.direction, args.duration, args.parallel, bw_str, args.timeout)
                    retry_step = {
                        "target_bps": down,
                        "target_str": bw_str,
                        "ok": False,
                        "fallback": True,
                    }
                    if "error" not in retry:
                        stats = extract_udp_stats(retry["data"])
                        retry_step.update(stats)
                        retry_step["cmd"] = retry.get("cmd")

                        loss = stats.get("loss_percent")
                        jitter = stats.get("jitter_ms")
                        throughput = stats.get("throughput_bps")
                        ok_retry = True
                        if loss is not None and loss > args.loss_threshold:
                            ok_retry = False
                        if jitter is not None and jitter > args.jitter_threshold:
                            ok_retry = False
                        if prev_throughput is not None and throughput is not None:
                            if throughput < prev_throughput * (1 - args.drop_threshold / 100.0):
                                ok_retry = False
                        retry_step["ok"] = ok_retry
                        steps.append(retry_step)
                        if ok_retry:
                            last_ok = retry_step
                            stop_reason = f"{stop_reason}_fallback_stepdown"
                break
            else:
                break

    output = {
        "meta": {
            **meta,
            "tool": "iperf3",
            "protocol": "udp",
            "direction": args.direction,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "adaptive": True,
            "loss_threshold": args.loss_threshold,
            "jitter_threshold": args.jitter_threshold,
            "drop_threshold": args.drop_threshold,
            "start_bps": start_bps,
            "step_bps": step_bps,
            "max_bps": max_bps,
        },
        "steps": steps,
        "selected": last_ok,
        "stop_reason": stop_reason,
    }

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
