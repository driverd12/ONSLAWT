#!/usr/bin/env python3
import argparse
import json
import os
import glob
from typing import Dict, Any, Tuple, List


def load_results(root: str) -> Dict[Tuple[str, str, str, str], Dict[str, Any]]:
    records: Dict[Tuple[str, str, str, str], Dict[str, Any]] = {}
    for path in glob.glob(os.path.join(root, "**", "*.json"), recursive=True):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            continue

        meta = data.get("meta") or {}
        summary = data.get("summary")
        if not meta or not isinstance(summary, dict):
            continue

        name = str(meta.get("name") or "")
        tool = str(meta.get("tool") or "")
        direction = str(meta.get("direction") or "")
        protocol = str(meta.get("protocol") or "")

        key = (name, tool, direction, protocol)
        records[key] = {
            "meta": meta,
            "summary": summary,
            "path": path,
        }
    return records


def pct_change(old: float, new: float):
    if old is None or new is None or old == 0:
        return None
    return ((new - old) / old) * 100.0


def human_bps(value: float) -> str:
    if value is None:
        return "n/a"
    units = [(1e9, "Gbps"), (1e6, "Mbps"), (1e3, "Kbps")]
    for scale, label in units:
        if value >= scale:
            return f"{value/scale:.3f} {label}"
    return f"{value:.3f} bps"


def format_value(metric: str, value):
    if value is None:
        return "n/a"
    if metric.endswith("_bps"):
        return human_bps(float(value))
    if metric.endswith("_percent"):
        return f"{float(value):.3f}%"
    return f"{float(value):.3f}"


def collect_rows(baseline: Dict, post: Dict) -> List[Dict[str, Any]]:
    rows = []
    all_keys = set(baseline.keys()) | set(post.keys())

    for key in sorted(all_keys):
        base_entry = baseline.get(key)
        post_entry = post.get(key)
        meta = (post_entry or base_entry or {}).get("meta", {})

        base_summary = (base_entry or {}).get("summary", {})
        post_summary = (post_entry or {}).get("summary", {})

        metrics = set(base_summary.keys()) | set(post_summary.keys())
        if not metrics:
            continue

        name, tool, direction, protocol = key
        for metric in sorted(metrics):
            base_val = base_summary.get(metric)
            post_val = post_summary.get(metric)
            delta = None
            if base_val is not None and post_val is not None:
                try:
                    delta = float(post_val) - float(base_val)
                except Exception:
                    delta = None
            pct = None
            if base_val is not None and post_val is not None:
                try:
                    pct = pct_change(float(base_val), float(post_val))
                except Exception:
                    pct = None

            rows.append({
                "name": name,
                "tool": tool,
                "direction": direction,
                "protocol": protocol,
                "metric": metric,
                "baseline": base_val,
                "post": post_val,
                "delta": delta,
                "pct": pct,
                "notes": meta.get("notes", ""),
            })

    return rows


def render_markdown(rows: List[Dict[str, Any]]) -> str:
    lines = []
    lines.append("| Test | Tool | Direction | Protocol | Metric | Baseline | Post | Delta | % Change |")
    lines.append("|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        baseline = format_value(r["metric"], r["baseline"])
        post = format_value(r["metric"], r["post"])
        delta = r["delta"]
        if delta is None:
            delta_str = "n/a"
        else:
            delta_str = format_value(r["metric"], delta)
        pct = r["pct"]
        pct_str = "n/a" if pct is None else f"{pct:.2f}%"
        lines.append(
            f"| {r['name']} | {r['tool']} | {r['direction'] or '-'} | {r['protocol'] or '-'} | {r['metric']} | {baseline} | {post} | {delta_str} | {pct_str} |"
        )
    return "\n".join(lines)


def render_csv(rows: List[Dict[str, Any]]) -> str:
    header = ["test", "tool", "direction", "protocol", "metric", "baseline", "post", "delta", "pct_change"]
    lines = [",".join(header)]
    for r in rows:
        pct = r["pct"]
        pct_str = "" if pct is None else f"{pct:.6f}"
        delta = r["delta"]
        delta_str = "" if delta is None else f"{delta:.6f}"
        line = [
            r["name"], r["tool"], r["direction"], r["protocol"], r["metric"],
            str(r["baseline"] or ""), str(r["post"] or ""), delta_str, pct_str,
        ]
        lines.append(",".join(line))
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Compare baseline and post-upgrade ONSLAWT results.")
    parser.add_argument("--baseline", required=True, help="Baseline results directory")
    parser.add_argument("--post", required=True, help="Post-upgrade results directory")
    parser.add_argument("--out", default="", help="Output file (Markdown or CSV)")
    args = parser.parse_args()

    baseline = load_results(args.baseline)
    post = load_results(args.post)
    rows = collect_rows(baseline, post)

    if not rows:
        output = "No comparable results found. Ensure both directories contain ONSLAWT JSON outputs."
    else:
        if args.out.lower().endswith(".csv"):
            output = render_csv(rows)
        else:
            output = render_markdown(rows)

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(output)
    else:
        print(output)


if __name__ == "__main__":
    main()
