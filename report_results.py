#!/usr/bin/env python3
import argparse
import json
import math
import os
import statistics
from typing import Dict, List, Any, Tuple


def load_results(run_dir: str) -> List[Dict[str, Any]]:
    rows = []
    for name in os.listdir(run_dir):
        if not (name.startswith("iperf_") or name.startswith("adaptive_udp_")) or not name.endswith(".json"):
            continue
        path = os.path.join(run_dir, name)
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            continue

        meta = data.get("meta", {})
        summary = data.get("summary", {})
        selected = data.get("selected")
        rows.append({
            "path": path,
            "meta": meta,
            "summary": summary,
            "selected": selected,
            "data": data,
        })
    return rows


def pct(v: float) -> str:
    return f"{v:.2f}%"


def fmt_bps(v: float) -> str:
    if v is None:
        return "n/a"
    v = float(v)
    if v >= 1e9:
        return f"{v/1e9:.3f} Gbps"
    if v >= 1e6:
        return f"{v/1e6:.3f} Mbps"
    if v >= 1e3:
        return f"{v/1e3:.3f} Kbps"
    return f"{v:.3f} bps"


def safe_float(x):
    try:
        return float(x)
    except Exception:
        return None


def iqr_outliers(values: List[float]) -> Tuple[List[float], float, float]:
    if len(values) < 4:
        return [], None, None
    sorted_vals = sorted(values)
    q1 = statistics.median(sorted_vals[: len(sorted_vals)//2])
    q3 = statistics.median(sorted_vals[(len(sorted_vals)+1)//2 :])
    iqr = q3 - q1
    low = q1 - 1.5 * iqr
    high = q3 + 1.5 * iqr
    outliers = [v for v in values if v < low or v > high]
    return outliers, low, high


def pearson(xs: List[float], ys: List[float]) -> float:
    if len(xs) < 2 or len(xs) != len(ys):
        return None
    mean_x = statistics.mean(xs)
    mean_y = statistics.mean(ys)
    num = sum((x-mean_x)*(y-mean_y) for x, y in zip(xs, ys))
    den_x = math.sqrt(sum((x-mean_x)**2 for x in xs))
    den_y = math.sqrt(sum((y-mean_y)**2 for y in ys))
    if den_x == 0 or den_y == 0:
        return None
    return num / (den_x * den_y)


def collect_metrics(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    metrics = []
    for row in rows:
        meta = row.get("meta", {})
        summary = row.get("summary", {})
        error = meta.get("error") or row.get("data", {}).get("error")
        # Adaptive UDP uses 'selected' for best step
        if not summary and row.get("selected"):
            sel = row.get("selected") or {}
            summary = {
                "udp_bps": sel.get("throughput_bps"),
                "udp_jitter_ms": sel.get("jitter_ms"),
                "udp_lost_percent": sel.get("loss_percent"),
                "udp_packets": sel.get("packets"),
            }
        protocol = meta.get("protocol")
        direction = meta.get("direction")
        host = meta.get("server_host")
        name = meta.get("name")

        rtt = safe_float(meta.get("rtt_avg_ms"))
        ttl = safe_float(meta.get("ttl_avg"))
        pfl = safe_float(meta.get("preflight_loss"))
        provider = meta.get("provider")
        site = meta.get("site")
        country = meta.get("country")
        continent = meta.get("continent")

        throughput = None
        if protocol == "tcp":
            if direction == "downlink":
                throughput = safe_float(summary.get("tcp_recv_bps"))
            else:
                throughput = safe_float(summary.get("tcp_sent_bps"))
        elif protocol == "udp":
            throughput = safe_float(summary.get("udp_bps"))

        jitter = safe_float(summary.get("udp_jitter_ms")) if protocol == "udp" else None
        loss = safe_float(summary.get("udp_lost_percent")) if protocol == "udp" else None

        metrics.append({
            "name": name,
            "host": host,
            "protocol": protocol,
            "direction": direction,
            "throughput_bps": throughput,
            "jitter_ms": jitter,
            "loss_percent": loss,
            "rtt_avg_ms": rtt,
            "ttl_avg": ttl,
            "preflight_loss": pfl,
            "provider": provider,
            "site": site,
            "country": country,
            "continent": continent,
            "error": error,
        })
    return metrics


def summarize(values: List[float]) -> Dict[str, Any]:
    if not values:
        return {
            "count": 0,
            "mean": None,
            "median": None,
            "min": None,
            "max": None,
            "stdev": None,
            "p10": None,
            "p90": None,
            "outliers": [],
            "iqr_low": None,
            "iqr_high": None,
        }
    vals = [v for v in values if v is not None]
    if not vals:
        return {
            "count": 0,
            "mean": None,
            "median": None,
            "min": None,
            "max": None,
            "stdev": None,
            "p10": None,
            "p90": None,
            "outliers": [],
            "iqr_low": None,
            "iqr_high": None,
        }
    vals_sorted = sorted(vals)
    p10 = vals_sorted[int(0.10*(len(vals_sorted)-1))]
    p90 = vals_sorted[int(0.90*(len(vals_sorted)-1))]
    outliers, low, high = iqr_outliers(vals)
    return {
        "count": len(vals),
        "mean": statistics.mean(vals),
        "median": statistics.median(vals),
        "min": min(vals),
        "max": max(vals),
        "stdev": statistics.pstdev(vals) if len(vals) > 1 else 0.0,
        "p10": p10,
        "p90": p90,
        "outliers": outliers,
        "iqr_low": low,
        "iqr_high": high,
    }


def group_key(m: Dict[str, Any]) -> Tuple[str, str, str]:
    return (m.get("host") or "", m.get("protocol") or "", m.get("direction") or "")


def build_tables(metrics: List[Dict[str, Any]]) -> Dict[str, Any]:
    grouped: Dict[Tuple[str, str, str], List[Dict[str, Any]]] = {}
    for m in metrics:
        grouped.setdefault(group_key(m), []).append(m)

    summaries = []
    for key, rows in grouped.items():
        host, protocol, direction = key
        tvals = [r["throughput_bps"] for r in rows if r["throughput_bps"] is not None]
        rttvals = [r["rtt_avg_ms"] for r in rows if r["rtt_avg_ms"] is not None]
        ttlvals = [r["ttl_avg"] for r in rows if r["ttl_avg"] is not None]
        pflvals = [r["preflight_loss"] for r in rows if r["preflight_loss"] is not None]
        jvals = [r["jitter_ms"] for r in rows if r["jitter_ms"] is not None]
        lvals = [r["loss_percent"] for r in rows if r["loss_percent"] is not None]

        summary = {
            "host": host,
            "protocol": protocol,
            "direction": direction,
            "provider": rows[0].get("provider"),
            "site": rows[0].get("site"),
            "country": rows[0].get("country"),
            "continent": rows[0].get("continent"),
            "throughput": summarize(tvals),
            "rtt": summarize(rttvals),
            "ttl": summarize(ttlvals),
            "preflight_loss": summarize(pflvals),
            "jitter": summarize(jvals),
            "loss": summarize(lvals),
        }
        summaries.append(summary)

    return {"summaries": summaries}


def svg_bar_chart(items: List[Dict[str, Any]], title: str, value_key: str, out_path: str, unit: str = "Gbps"):
    # Simple SVG bar chart. No external deps.
    width = 1000
    height = 400
    margin = 60

    values = [i.get(value_key) or 0 for i in items]
    max_val = max(values) if values else 1
    if max_val <= 0:
        max_val = 1

    bar_width = (width - 2*margin) / max(1, len(items))

    def y(v):
        return height - margin - (v / max_val) * (height - 2*margin)

    lines = [f"<svg xmlns='http://www.w3.org/2000/svg' width='{width}' height='{height}'>"]
    lines.append(f"<text x='{width/2}' y='24' text-anchor='middle' font-size='18' font-family='sans-serif'>{title}</text>")
    lines.append(f"<line x1='{margin}' y1='{height-margin}' x2='{width-margin}' y2='{height-margin}' stroke='#333'/>")
    lines.append(f"<line x1='{margin}' y1='{margin}' x2='{margin}' y2='{height-margin}' stroke='#333'/>")

    for idx, item in enumerate(items):
        val = item.get(value_key) or 0
        x = margin + idx * bar_width + 4
        bar_h = (val / max_val) * (height - 2*margin)
        lines.append(f"<rect x='{x}' y='{height-margin-bar_h}' width='{bar_width-8}' height='{bar_h}' fill='#4e79a7'/>")
        label = item.get("label") or ""
        lines.append(f"<text x='{x + (bar_width-8)/2}' y='{height - margin + 14}' text-anchor='middle' font-size='9' font-family='sans-serif'>{label}</text>")

    lines.append(f"<text x='{margin}' y='{margin-10}' font-size='10' font-family='sans-serif'>{unit}</text>")
    lines.append("</svg>")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def svg_scatter(items: List[Dict[str, Any]], title: str, out_path: str):
    width = 800
    height = 400
    margin = 60

    xs = [i.get("x") for i in items if i.get("x") is not None]
    ys = [i.get("y") for i in items if i.get("y") is not None]
    if not xs or not ys:
        return
    min_x, max_x = min(xs), max(xs)
    min_y, max_y = min(ys), max(ys)
    if max_x == min_x:
        max_x += 1
    if max_y == min_y:
        max_y += 1

    def map_x(v):
        return margin + (v - min_x) / (max_x - min_x) * (width - 2*margin)

    def map_y(v):
        return height - margin - (v - min_y) / (max_y - min_y) * (height - 2*margin)

    lines = [f"<svg xmlns='http://www.w3.org/2000/svg' width='{width}' height='{height}'>"]
    lines.append(f"<text x='{width/2}' y='24' text-anchor='middle' font-size='18' font-family='sans-serif'>{title}</text>")
    lines.append(f"<line x1='{margin}' y1='{height-margin}' x2='{width-margin}' y2='{height-margin}' stroke='#333'/>")
    lines.append(f"<line x1='{margin}' y1='{margin}' x2='{margin}' y2='{height-margin}' stroke='#333'/>")

    for item in items:
        x = item.get("x")
        yv = item.get("y")
        if x is None or yv is None:
            continue
        cx = map_x(x)
        cy = map_y(yv)
        lines.append(f"<circle cx='{cx}' cy='{cy}' r='4' fill='#f28e2b'/>")

    lines.append(f"<text x='{width/2}' y='{height-10}' text-anchor='middle' font-size='10' font-family='sans-serif'>RTT avg (ms)</text>")
    lines.append(f"<text x='12' y='{height/2}' text-anchor='middle' font-size='10' font-family='sans-serif' transform='rotate(-90 12 {height/2})'>Throughput (Gbps)</text>")
    lines.append("</svg>")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def write_html_report(run_dir: str, device: str, summaries: List[Dict[str, Any]], metrics: List[Dict[str, Any]], graphs: List[Tuple[str, str]]):
    html_path = os.path.join(run_dir, "report.html")
    lines = []
    lines.append("<!doctype html>")
    lines.append("<html><head><meta charset='utf-8'/>")
    lines.append("<style>")
    lines.append("body{font-family:Arial,Helvetica,sans-serif;margin:24px;color:#111}")
    lines.append("h1,h2{margin:0.4em 0}")
    lines.append("table{border-collapse:collapse;width:100%;margin:12px 0;font-size:13px}")
    lines.append("th,td{border:1px solid #ddd;padding:6px 8px;text-align:left}")
    lines.append("th{background:#f5f5f5}")
    lines.append(".meta{margin-bottom:16px}")
    lines.append("</style></head><body>")

    lines.append("<h1>ONSLAWT Report</h1>")
    lines.append(f"<div class='meta'><strong>Device:</strong> {device}<br/><strong>Run directory:</strong> {run_dir}</div>")

    # Per-endpoint summary table
    lines.append("<h2>Per-Endpoint Summary (Throughput)</h2>")
    lines.append("<table><tr><th>Host</th><th>Protocol</th><th>Direction</th><th>Site</th><th>Provider</th>"
                 "<th>Mean</th><th>Median</th><th>Min</th><th>Max</th><th>P10</th><th>P90</th><th>Outliers</th>"
                 "<th>RTT Mean</th><th>TTL Mean</th><th>Ping Loss %</th></tr>")
    for s in summaries:
        t = s["throughput"]
        r = s["rtt"]
        ttl = s["ttl"]
        pfl = s["preflight_loss"]
        rtt_str = f"{r['mean']:.3f} ms" if r["mean"] is not None else "n/a"
        ttl_str = f"{ttl['mean']:.1f}" if ttl["mean"] is not None else "n/a"
        pfl_str = f"{pfl['mean']:.2f}%" if pfl["mean"] is not None else "n/a"
        lines.append(
            "<tr>"
            f"<td>{s['host']}</td>"
            f"<td>{s['protocol']}</td>"
            f"<td>{s['direction']}</td>"
            f"<td>{s.get('site') or '-'}</td>"
            f"<td>{s.get('provider') or '-'}</td>"
            f"<td>{fmt_bps(t['mean'])}</td>"
            f"<td>{fmt_bps(t['median'])}</td>"
            f"<td>{fmt_bps(t['min'])}</td>"
            f"<td>{fmt_bps(t['max'])}</td>"
            f"<td>{fmt_bps(t['p10'])}</td>"
            f"<td>{fmt_bps(t['p90'])}</td>"
            f"<td>{len(t['outliers'])}</td>"
            f"<td>{rtt_str}</td>"
            f"<td>{ttl_str}</td>"
            f"<td>{pfl_str}</td>"
            "</tr>"
        )
    lines.append("</table>")

    # Overall summary
    lines.append("<h2>Overall Summary (All Endpoints)</h2>")
    lines.append("<table><tr><th>Protocol</th><th>Direction</th><th>Mean</th><th>Median</th><th>Min</th><th>Max</th><th>P10</th><th>P90</th><th>Outliers</th></tr>")
    by_pd: Dict[tuple, List[float]] = {}
    for m in metrics:
        key = (m.get("protocol"), m.get("direction"))
        if m.get("throughput_bps") is not None:
            by_pd.setdefault(key, []).append(m.get("throughput_bps"))
    for (proto, direction), vals in by_pd.items():
        s = summarize(vals)
        lines.append(
            f"<tr><td>{proto}</td><td>{direction}</td>"
            f"<td>{fmt_bps(s['mean'])}</td><td>{fmt_bps(s['median'])}</td>"
            f"<td>{fmt_bps(s['min'])}</td><td>{fmt_bps(s['max'])}</td>"
            f"<td>{fmt_bps(s['p10'])}</td><td>{fmt_bps(s['p90'])}</td>"
            f"<td>{len(s['outliers'])}</td></tr>"
        )
    lines.append("</table>")

    # UDP jitter/loss
    udp_rows = [s for s in summaries if s["protocol"] == "udp"]
    if udp_rows:
        lines.append("<h2>UDP Jitter/Loss</h2>")
        lines.append("<table><tr><th>Host</th><th>Direction</th><th>Jitter Mean (ms)</th><th>Loss Mean (%)</th></tr>")
        for s in udp_rows:
            j = s["jitter"]["mean"]
            l = s["loss"]["mean"]
            lines.append(
                f"<tr><td>{s['host']}</td><td>{s['direction']}</td>"
                f"<td>{f'{j:.3f}' if j is not None else 'n/a'}</td>"
                f"<td>{f'{l:.3f}' if l is not None else 'n/a'}</td></tr>"
            )
        lines.append("</table>")

    # Graphs
    if graphs:
        lines.append("<h2>Graphs</h2>")
        for title, path in graphs:
            lines.append(f"<div><strong>{title}</strong><br/><img src='{path}' style='max-width:100%;' /></div><br/>")

    lines.append("</body></html>")

    with open(html_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def write_report(run_dir: str, device: str, metrics: List[Dict[str, Any]], summaries: List[Dict[str, Any]], out_path: str):
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    lines = []
    lines.append(f"# ONSLAWT Report")
    lines.append("")
    lines.append(f"Device: **{device}**")
    lines.append(f"Run directory: `{run_dir}`")
    lines.append("")
    total_samples = len(metrics)
    good_samples = len([m for m in metrics if m.get("throughput_bps") is not None])
    failures = [m for m in metrics if m.get("throughput_bps") is None]
    lines.append(f"Samples: **{good_samples}/{total_samples}** with throughput data. Failures: **{len(failures)}**.")
    if failures:
        fail_list = ", ".join([f"{m.get('host','?')} ({m.get('protocol','?')} {m.get('direction','?')})" for m in failures[:8]])
        lines.append(f"Failures (first 8): {fail_list}")
    if good_samples == 0:
        lines.append("No throughput data was captured. Check iperf errors in run.log and reduce load or parallelism.")
    lines.append("")

    # Summary table
    lines.append("## Per-Endpoint Summary (Throughput)")
    lines.append("| Host | Protocol | Direction | Site | Provider | Mean | Median | Min | Max | P10 | P90 | Outliers | RTT Mean | TTL Mean | Ping Loss % |")
    lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for s in summaries:
        t = s["throughput"]
        r = s["rtt"]
        ttl = s["ttl"]
        pfl = s["preflight_loss"]
        lines.append(
            "| {host} | {protocol} | {direction} | {site} | {provider} | {mean} | {median} | {minv} | {maxv} | {p10} | {p90} | {outliers} | {rtt} | {ttl} | {pfl} |".format(
                host=s["host"],
                protocol=s["protocol"],
                direction=s["direction"],
                site=s.get("site") or "-",
                provider=s.get("provider") or "-",
                mean=fmt_bps(t["mean"]),
                median=fmt_bps(t["median"]),
                minv=fmt_bps(t["min"]),
                maxv=fmt_bps(t["max"]),
                p10=fmt_bps(t["p10"]),
                p90=fmt_bps(t["p90"]),
                outliers=len(t["outliers"]),
                rtt=f"{r['mean']:.3f} ms" if r["mean"] is not None else "n/a",
                ttl=f"{ttl['mean']:.1f}" if ttl["mean"] is not None else "n/a",
                pfl=f"{pfl['mean']:.2f}%" if pfl["mean"] is not None else "n/a",
            )
        )

    # Correlation
    lines.append("")
    lines.append("## Correlation (RTT vs Throughput)")
    for proto in ("tcp", "udp"):
        vals = [(m.get("rtt_avg_ms"), m.get("throughput_bps")) for m in metrics if m.get("protocol") == proto]
        xs = [v[0] for v in vals if v[0] is not None and v[1] is not None]
        ys = [v[1] for v in vals if v[0] is not None and v[1] is not None]
        corr = pearson(xs, ys)
        if corr is None:
            lines.append(f"- {proto.upper()}: n/a")
        else:
            lines.append(f"- {proto.upper()}: {corr:.3f}")

    # UDP stats
    udp_rows = [s for s in summaries if s["protocol"] == "udp"]
    if udp_rows:
        lines.append("")
        lines.append("## UDP Jitter/Loss")
        lines.append("| Host | Direction | Jitter Mean (ms) | Loss Mean (%) |")
        lines.append("|---|---|---|---|")
        for s in udp_rows:
            j = s["jitter"]["mean"]
            l = s["loss"]["mean"]
            lines.append(
                f"| {s['host']} | {s['direction']} | {j:.3f} | {l:.3f} |" if j is not None and l is not None else f"| {s['host']} | {s['direction']} | n/a | n/a |"
            )

    # Overall summary by protocol+direction
    lines.append("")
    lines.append("## Overall Summary (All Endpoints)")
    lines.append("| Protocol | Direction | Mean | Median | Min | Max | P10 | P90 | Outliers |")
    lines.append("|---|---|---|---|---|---|---|---|---|")
    by_pd: Dict[tuple, List[float]] = {}
    for m in metrics:
        key = (m.get("protocol"), m.get("direction"))
        if m.get("throughput_bps") is not None:
            by_pd.setdefault(key, []).append(m.get("throughput_bps"))
    for (proto, direction), vals in by_pd.items():
        s = summarize(vals)
        lines.append(
            f"| {proto} | {direction} | {fmt_bps(s['mean'])} | {fmt_bps(s['median'])} | {fmt_bps(s['min'])} | {fmt_bps(s['max'])} | {fmt_bps(s['p10'])} | {fmt_bps(s['p90'])} | {len(s['outliers'])} |"
        )

    # Graphs
    assets_dir = os.path.join(run_dir, "report_assets")
    os.makedirs(assets_dir, exist_ok=True)

    graphs = []

    # Bar chart for TCP uplink mean throughput
    tcp_uplink = []
    for s in summaries:
        if s["protocol"] == "tcp" and s["direction"] == "uplink":
            tcp_uplink.append({
                "label": (s.get("site") or s["host"])[:10],
                "value": (s["throughput"]["mean"] or 0) / 1e9,
            })
    if tcp_uplink:
        out_svg = os.path.join(assets_dir, "tcp_uplink_mean.svg")
        svg_bar_chart(tcp_uplink, "TCP Uplink Mean Throughput (Gbps)", "value", out_svg, unit="Gbps")
        graphs.append(("TCP Uplink Mean", "report_assets/tcp_uplink_mean.svg"))

    # Bar chart for TCP downlink
    tcp_down = []
    for s in summaries:
        if s["protocol"] == "tcp" and s["direction"] == "downlink":
            tcp_down.append({
                "label": (s.get("site") or s["host"])[:10],
                "value": (s["throughput"]["mean"] or 0) / 1e9,
            })
    if tcp_down:
        out_svg = os.path.join(assets_dir, "tcp_downlink_mean.svg")
        svg_bar_chart(tcp_down, "TCP Downlink Mean Throughput (Gbps)", "value", out_svg, unit="Gbps")
        graphs.append(("TCP Downlink Mean", "report_assets/tcp_downlink_mean.svg"))

    # UDP mean throughput
    udp = []
    for s in summaries:
        if s["protocol"] == "udp":
            udp.append({
                "label": (s.get("site") or s["host"])[:10],
                "value": (s["throughput"]["mean"] or 0) / 1e9,
            })
    if udp:
        out_svg = os.path.join(assets_dir, "udp_mean.svg")
        svg_bar_chart(udp, "UDP Mean Throughput (Gbps)", "value", out_svg, unit="Gbps")
        graphs.append(("UDP Mean", "report_assets/udp_mean.svg"))

    # RTT mean
    rtt_bars = []
    for s in summaries:
        if s["rtt"]["mean"] is not None:
            rtt_bars.append({
                "label": (s.get("site") or s["host"])[:10],
                "value": s["rtt"]["mean"],
            })
    if rtt_bars:
        out_svg = os.path.join(assets_dir, "rtt_mean.svg")
        svg_bar_chart(rtt_bars, "RTT Mean (ms)", "value", out_svg, unit="ms")
        graphs.append(("RTT Mean", "report_assets/rtt_mean.svg"))

    # UDP jitter mean
    jitter_bars = []
    for s in summaries:
        if s["protocol"] == "udp" and s["jitter"]["mean"] is not None:
            jitter_bars.append({
                "label": (s.get("site") or s["host"])[:10],
                "value": s["jitter"]["mean"],
            })
    if jitter_bars:
        out_svg = os.path.join(assets_dir, "udp_jitter_mean.svg")
        svg_bar_chart(jitter_bars, "UDP Jitter Mean (ms)", "value", out_svg, unit="ms")
        graphs.append(("UDP Jitter Mean", "report_assets/udp_jitter_mean.svg"))

    # UDP loss mean
    loss_bars = []
    for s in summaries:
        if s["protocol"] == "udp" and s["loss"]["mean"] is not None:
            loss_bars.append({
                "label": (s.get("site") or s["host"])[:10],
                "value": s["loss"]["mean"],
            })
    if loss_bars:
        out_svg = os.path.join(assets_dir, "udp_loss_mean.svg")
        svg_bar_chart(loss_bars, "UDP Loss Mean (%)", "value", out_svg, unit="%")
        graphs.append(("UDP Loss Mean", "report_assets/udp_loss_mean.svg"))

    # RTT vs throughput scatter
    scatter_items = []
    for m in metrics:
        if m.get("rtt_avg_ms") is not None and m.get("throughput_bps") is not None:
            scatter_items.append({
                "x": m["rtt_avg_ms"],
                "y": m["throughput_bps"] / 1e9,
            })
    if scatter_items:
        out_svg = os.path.join(assets_dir, "rtt_vs_throughput.svg")
        svg_scatter(scatter_items, "RTT vs Throughput", out_svg)
        graphs.append(("RTT vs Throughput", "report_assets/rtt_vs_throughput.svg"))

    if graphs:
        lines.append("")
        lines.append("## Graphs")
        for title, path in graphs:
            lines.append(f"![{title}]({path})")

    # Write HTML report alongside markdown
    write_html_report(run_dir, device, summaries, metrics, graphs)

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description="Generate ONSLAWT report with stats and graphs")
    parser.add_argument("--run-dir", required=True, help="results/<run_id> directory")
    parser.add_argument("--device", required=True, help="Device label (palo-3220 or mx-450)")
    parser.add_argument("--out", default="", help="Output report markdown file")
    args = parser.parse_args()

    run_dir = args.run_dir
    if not os.path.isdir(run_dir):
        raise SystemExit(f"Run directory not found: {run_dir}")

    rows = load_results(run_dir)
    metrics = collect_metrics(rows)
    summary_data = build_tables(metrics)

    out_path = args.out or os.path.join(run_dir, "report.md")
    write_report(run_dir, args.device, metrics, summary_data["summaries"], out_path)
    print(f"Report written to: {out_path}")


if __name__ == "__main__":
    main()
