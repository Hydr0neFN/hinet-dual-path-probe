#!/usr/bin/env python3
"""Turn the raw probe CSV into the published artefacts.

Runs on the Pi itself, so: standard library only, no numpy, no matplotlib.

Outputs (all under data/):
  paired-scrubbed.csv  raw samples with the source-IP column removed
  stats.md             the table view - required, since a README image cannot be hovered
  chart-light.svg      \\ two selected themes, not one auto-inverted; GitHub picks
  chart-dark.svg       /  between them with <picture media="(prefers-color-scheme: dark)">

Chart form: latency and packet loss are different measures on different scales, so
they get separate panels sharing one time axis. Never a second y-axis.
"""
import csv, sys, os, datetime, statistics as st

SRC = sys.argv[1] if len(sys.argv) > 1 else "/root/netmeasure/paired.csv"
OUT = sys.argv[2] if len(sys.argv) > 2 else "data"
WINDOW_H = int(os.environ.get("WINDOW_HOURS", "48"))
BUCKET_MIN = 10          # median over 10 min keeps the SVG small and the line readable
GAP_BREAK_MIN = 25       # never draw a line across an outage. Must exceed BUCKET_MIN,
                         # or every adjacent bucket reads as a gap and the chart
                         # degenerates into isolated dots.

LABEL = {"modem": "Static IP (固定制)", "pppoe": "Dynamic IP (浮動制)"}
ORDER = ["modem", "pppoe"]

THEME = {
    "light": dict(surface="#fcfcfb", ink="#0b0b0b", ink2="#52514e", ink3="#8a8880",
                  grid="#e6e5e0", series={"modem": "#2a78d6", "pppoe": "#eb6834"}),
    "dark":  dict(surface="#1a1a19", ink="#ffffff", ink2="#c3c2b7", ink3="#8a8880",
                  grid="#2e2e2c", series={"modem": "#3987e5", "pppoe": "#d95926"}),
}


def load(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            if not r.get("ts") or r.get("path") not in LABEL:
                continue
            try:
                r["_t"] = datetime.datetime.strptime(r["ts"], "%Y-%m-%d %H:%M:%S")
            except ValueError:
                continue
            rows.append(r)
    rows.sort(key=lambda r: r["_t"])
    return rows


def num(v):
    try:
        x = float(v)
        return x if x >= 0 else None
    except (TypeError, ValueError):
        return None


def bucket(rows, field, path):
    """median of `field` per BUCKET_MIN bucket, for one path"""
    acc = {}
    for r in rows:
        if r["path"] != path:
            continue
        v = num(r.get(field))
        if v is None:
            continue
        t = r["_t"]
        key = t.replace(minute=(t.minute // BUCKET_MIN) * BUCKET_MIN, second=0)
        acc.setdefault(key, []).append(v)
    return sorted((k, st.median(v)) for k, v in acc.items())


def loss_rate(rows, path):
    """percentage of samples in each bucket that reported any loss"""
    acc = {}
    for r in rows:
        if r["path"] != path:
            continue
        vals = [num(r.get(k)) for k in ("tokyo_loss", "cf_loss", "goog_loss")]
        vals = [v for v in vals if v is not None]
        if not vals:
            continue
        t = r["_t"]
        key = t.replace(minute=(t.minute // BUCKET_MIN) * BUCKET_MIN, second=0)
        acc.setdefault(key, []).append(max(vals))
    return sorted((k, sum(1 for x in v if x > 0) / len(v) * 100) for k, v in acc.items())


def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def svg(series_by_panel, t0, t1, theme_name, path_out):
    """series_by_panel: [(title, unit, {path: [(t, v)]}), ...]"""
    T = THEME[theme_name]
    W, PAD_L, PAD_R, PAD_T = 900, 62, 132, 34
    PH, GAP = 132, 40                       # panel height / gap between panels
    n = len(series_by_panel)
    H = PAD_T + n * PH + (n - 1) * GAP + 52

    span = max((t1 - t0).total_seconds(), 1)

    def X(t):
        return PAD_L + (t - t0).total_seconds() / span * (W - PAD_L - PAD_R)

    o = []
    a = o.append
    a(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
      f'viewBox="0 0 {W} {H}" font-family="ui-sans-serif,-apple-system,Segoe UI,Helvetica,Arial,sans-serif">')
    a(f'<rect width="{W}" height="{H}" fill="{T["surface"]}"/>')

    # legend - always present for >=2 series; identity is never colour-alone because
    # each line is also directly labelled at its right end
    lx = PAD_L
    for p in ORDER:
        a(f'<rect x="{lx}" y="{PAD_T-24}" width="10" height="10" rx="2" fill="{T["series"][p]}"/>')
        a(f'<text x="{lx+16}" y="{PAD_T-15}" font-size="12" fill="{T["ink2"]}">{esc(LABEL[p])}</text>')
        lx += 190

    for pi, (title, unit, data) in enumerate(series_by_panel):
        top = PAD_T + pi * (PH + GAP)
        bot = top + PH
        vals = [v for p in ORDER for _, v in data.get(p, [])]
        vmax = max(vals) if vals else 1
        vmax = max(vmax * 1.15, 1)

        def Y(v):
            return bot - (v / vmax) * PH

        a(f'<text x="{PAD_L}" y="{top-8}" font-size="13" font-weight="600" fill="{T["ink"]}">{esc(title)}</text>')

        # recessive grid + y labels
        for frac in (0, 0.5, 1.0):
            v = vmax * frac
            y = Y(v)
            a(f'<line x1="{PAD_L}" y1="{y:.1f}" x2="{W-PAD_R}" y2="{y:.1f}" '
              f'stroke="{T["grid"]}" stroke-width="1"/>')
            a(f'<text x="{PAD_L-8}" y="{y+4:.1f}" font-size="11" text-anchor="end" '
              f'fill="{T["ink3"]}">{v:.0f}</text>')
        a(f'<text x="14" y="{(top+bot)/2:.1f}" font-size="11" fill="{T["ink3"]}" '
          f'transform="rotate(-90 14 {(top+bot)/2:.1f})" text-anchor="middle">{esc(unit)}</text>')

        endlabels = []
        for p in ORDER:
            pts = data.get(p, [])
            if not pts:
                continue
            # break the path across outages instead of drawing a straight lie through them
            segs, cur = [], []
            prev = None
            for t, v in pts:
                if prev and (t - prev).total_seconds() > GAP_BREAK_MIN * 60:
                    segs.append(cur); cur = []
                cur.append((t, v)); prev = t
            if cur:
                segs.append(cur)
            for seg in segs:
                if len(seg) == 1:
                    t, v = seg[0]
                    a(f'<circle cx="{X(t):.1f}" cy="{Y(v):.1f}" r="2" fill="{T["series"][p]}"/>')
                    continue
                d = " ".join(("M" if i == 0 else "L") + f"{X(t):.1f} {Y(v):.1f}"
                             for i, (t, v) in enumerate(seg))
                a(f'<path d="{d}" fill="none" stroke="{T["series"][p]}" stroke-width="2" '
                  f'stroke-linejoin="round" stroke-linecap="round"/>')
            # direct label at the right end - secondary encoding, so colour is never the only cue
            t, v = pts[-1]
            endlabels.append([Y(v), f'{LABEL[p].split(" (")[0]} {v:.0f}'])

        # Nudge end labels apart when the two series land on nearly the same value,
        # otherwise the labels overprint and the secondary encoding is lost.
        endlabels.sort(key=lambda e: e[0])
        for i in range(1, len(endlabels)):
            if endlabels[i][0] - endlabels[i - 1][0] < 13:
                endlabels[i][0] = endlabels[i - 1][0] + 13
        shift = max(0.0, endlabels[-1][0] - bot) if endlabels else 0.0
        for ly, text in endlabels:
            a(f'<text x="{W-PAD_R+8}" y="{ly - shift + 4:.1f}" font-size="11" '
              f'fill="{T["ink2"]}">{esc(text)}</text>')

        a(f'<line x1="{PAD_L}" y1="{bot}" x2="{W-PAD_R}" y2="{bot}" stroke="{T["ink3"]}" stroke-width="1"/>')

    # shared time axis
    y = PAD_T + n * PH + (n - 1) * GAP + 18
    steps = 6
    for i in range(steps + 1):
        t = t0 + datetime.timedelta(seconds=span * i / steps)
        a(f'<text x="{X(t):.1f}" y="{y}" font-size="11" text-anchor="middle" '
          f'fill="{T["ink3"]}">{t.strftime("%m-%d %H:%M")}</text>')
    a(f'<text x="{PAD_L}" y="{y+20}" font-size="11" fill="{T["ink3"]}">'
      f'{esc(f"{BUCKET_MIN}-minute medians · both paths measured from one host at the same instant · times UTC+8")}</text>')
    a("</svg>")
    open(path_out, "w", encoding="utf-8").write("\n".join(o))


def main():
    rows = load(SRC)
    if not rows:
        print("no rows", file=sys.stderr)
        return 1
    os.makedirs(OUT, exist_ok=True)

    cutoff = rows[-1]["_t"] - datetime.timedelta(hours=WINDOW_H)
    win = [r for r in rows if r["_t"] >= cutoff]
    t0, t1 = win[0]["_t"], win[-1]["_t"]

    panels = [
        ("Cloudflare 1.1.1.1 — round-trip time", "ms",
         {p: bucket(win, "cf_avg", p) for p in ORDER}),
        ("Steam Datagram Relay, Tokyo — round-trip time (the path CS2 actually uses)", "ms",
         {p: bucket(win, "sdr_udp_rtt", p) for p in ORDER}),
        ("Samples reporting packet loss", "%",
         {p: loss_rate(win, p) for p in ORDER}),
    ]
    for name in ("light", "dark"):
        svg(panels, t0, t1, name, os.path.join(OUT, f"chart-{name}.svg"))

    # scrubbed raw data - the src column is a public IP address
    with open(os.path.join(OUT, "paired-scrubbed.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["ts", "path", "tokyo_avg", "tokyo_loss", "cf_avg", "cf_loss",
                    "goog_avg", "goog_loss", "sdr_udp_rtt"])
        for r in rows:
            w.writerow([r["ts"], r["path"], r.get("tokyo_avg", ""), r.get("tokyo_loss", ""),
                        r.get("cf_avg", ""), r.get("cf_loss", ""), r.get("goog_avg", ""),
                        r.get("goog_loss", ""), r.get("sdr_udp_rtt", "")])

    # table view
    def agg(field, p, subset):
        v = [x for x in (num(r.get(field)) for r in subset if r["path"] == p) if x]
        if not v:
            return None
        v.sort()
        return st.median(v), v[min(len(v) - 1, int(len(v) * 0.95))]

    lines = ["# Measured results", "",
             f"Window: `{rows[0]['ts']}` → `{rows[-1]['ts']}` · **{len(rows)} samples** "
             f"(`{sum(1 for r in rows if r['path']=='modem')}` per path)", "",
             "Both paths are measured from the same host, in the same loop iteration, "
             "microseconds apart — so any difference is the path, not the moment.", "",
             "| metric | Static IP median | Static IP p95 | Dynamic IP median | Dynamic IP p95 |",
             "|---|---|---|---|---|"]
    for field, name in (("sdr_udp_rtt", "Tokyo SDR relay, UDP RTT (ms)"),
                        ("tokyo_avg", "Tokyo SDR relay, ICMP RTT (ms)"),
                        ("cf_avg", "Cloudflare 1.1.1.1 RTT (ms)"),
                        ("goog_avg", "Google 8.8.8.8 RTT (ms)")):
        a1, a2 = agg(field, "modem", rows), agg(field, "pppoe", rows)
        if a1 and a2:
            lines.append(f"| {name} | {a1[0]:.0f} | {a1[1]:.0f} | {a2[0]:.0f} | {a2[1]:.0f} |")

    lines += ["", "## Same-instant deltas (dynamic minus static)", "",
              "| metric | median | p95 | share of samples where dynamic is worse by >5 ms |",
              "|---|---|---|---|"]
    by_ts = {}
    for r in rows:
        by_ts.setdefault(r["ts"], {})[r["path"]] = r
    pairs = [v for v in by_ts.values() if len(v) == 2]
    for field, name in (("sdr_udp_rtt", "Tokyo SDR relay, UDP RTT"),
                        ("tokyo_avg", "Tokyo SDR relay, ICMP RTT"),
                        ("cf_avg", "Cloudflare 1.1.1.1 RTT"),
                        ("goog_avg", "Google 8.8.8.8 RTT")):
        d = []
        for p in pairs:
            x, y = num(p["modem"].get(field)), num(p["pppoe"].get(field))
            if x and y:
                d.append(y - x)
        if d:
            d.sort()
            p95 = d[min(len(d) - 1, int(len(d) * 0.95))]
            worse = sum(1 for v in d if v > 5) / len(d) * 100
            lines.append(f"| {name} | {st.median(d):+.0f} ms | {p95:+.0f} ms | {worse:.1f}% |")

    lines += ["", f"_Regenerated automatically from the live probe. Last update: "
                  f"{datetime.datetime.now().strftime('%Y-%m-%d %H:%M')} (UTC+8)._"]
    open(os.path.join(OUT, "stats.md"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
    print(f"wrote {OUT}/chart-light.svg, chart-dark.svg, stats.md, paired-scrubbed.csv "
          f"({len(rows)} rows, window {WINDOW_H}h)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
