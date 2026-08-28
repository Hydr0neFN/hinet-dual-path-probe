#!/usr/bin/env python3
"""Daily rollup of the paired probe, so the repo shows an evolving history and not just a
rolling 48-hour window.

The main chart always renders "the last two days", which means a quiet day produces no
visible change at all and the hourly publish commits nothing. This writes one row per
calendar day per path instead: the file gains a row every day and the current day's row
keeps moving, so there is always something to look at in the diff.

Palette, labels and series order are imported from gen_report so the two charts can never
drift apart. Stdlib only -- this runs on the Pi.
"""
import csv
import datetime
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_report as gr

SRC = sys.argv[1] if len(sys.argv) > 1 else "/root/netmeasure/paired.csv"
OUT = sys.argv[2] if len(sys.argv) > 2 else "data"
MAX_DAYS = int(os.environ.get("HISTORY_DAYS", "30"))
MIN_SAMPLES = 12          # a day with fewer samples than this is noise, not a data point

FIELDS = [("sdr_udp_rtt", "p95"), ("cf_avg", "med"), ("jit_mdev", "med")]
TITLES = {
    "zh": ["遊戲路徑 p95 · SDR relay RTT", "Cloudflare 1.1.1.1 中位數",
           "遊戲路徑抖動 · 每輪 20 pps 突發的 mdev 中位數"],
    "en": ["Game path p95 · SDR relay RTT", "Cloudflare 1.1.1.1 median",
           "Game-path jitter · median mdev of a 20 pps burst per cycle"],
}
CAPTION = {
    "zh": "每日彙整 · 最後一天仍在累積中 · 產生時間 %s",
    "en": "Daily rollup · the last day is still accumulating · generated %s",
}
UNIT = "ms"

# kept so the rollup/CSV code below can stay locale-free
PANELS = [(f, st, TITLES["zh"][i], UNIT) for i, (f, st) in enumerate(FIELDS)]


def ceiling(v):
    """Axis top with finer steps than gen_report's 1/2/2.5/5.

    Daily maxima cluster in the 20-60 ms range, where the coarse ladder rounds 57 to 100
    and 25 to 50 -- half the panel left empty and both series pressed into the baseline.
    The headroom is 4%, not 15%, because the end labels sit outside the plot area, so a
    point near the top edge collides with nothing.
    """
    import math
    if v <= 0:
        return 1
    exp = math.floor(math.log10(v))
    base = 10.0 ** exp
    for m in (1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10):
        if v <= m * base:
            top = m * base
            return int(top) if top == int(top) else top
    return int(10 * base)


def pct(values, q):
    """Nearest-rank percentile. q=0.5 gives the median."""
    if not values:
        return None
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round(q * (len(s) - 1)))))
    return s[k]


def rollup(rows):
    """{(day, path): {field: {'med': x, 'p95': y, 'n': k}}}"""
    acc = {}
    for r in rows:
        key = (r["_t"].date(), r["path"])
        for field, _, _, _ in PANELS:
            v = gr.num(r.get(field))
            if v is None:
                continue
            acc.setdefault(key, {}).setdefault(field, []).append(v)
    out = {}
    for key, fields in acc.items():
        day = {}
        for field, vals in fields.items():
            if len(vals) < MIN_SAMPLES:
                continue
            day[field] = {"med": pct(vals, 0.5), "p95": pct(vals, 0.95), "n": len(vals)}
        if day:
            out[key] = day
    return out


def write_csv(daily, path_out):
    days = sorted({d for d, _ in daily})
    with open(path_out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["date", "path", "field", "median_ms", "p95_ms", "samples"])
        for d in days:
            for p in gr.ORDER:
                day = daily.get((d, p))
                if not day:
                    continue
                for field, _, _, _ in PANELS:
                    st = day.get(field)
                    if not st:
                        continue
                    w.writerow([d.isoformat(), p, field,
                                "%.1f" % st["med"], "%.1f" % st["p95"], st["n"]])
    return days


def svg(daily, days, theme_name, path_out, loc="zh"):
    th = gr.THEME[theme_name]
    # PAD_T has to clear the legend band, not just the panel title: at 34 the legend
    # (baseline 24) and the first title (baseline PAD_T-9 = 25) printed on top of
    # each other, both starting at PAD_L.
    W, PH, PAD_L, PAD_R, PAD_T, GAP = 880, 150, 58, 96, 60, 34
    nlive = sum(1 for f, _s, _t, _u in PANELS
                if any(f in daily.get((d, p), {}) for d in days for p in gr.ORDER))
    H = PAD_T + max(1, nlive) * (PH + GAP) + 26
    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
         'font-family="ui-sans-serif,-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif">'
         % (W, H, W, H),
         '<rect width="%d" height="%d" fill="%s"/>' % (W, H, th["surface"])]

    # Days are evenly spaced rather than time-proportional: with a handful of days a
    # proportional axis crushes them into the left edge and reads as a single blob.
    n = len(days)
    plot_w = W - PAD_L - PAD_R

    def X(i):
        return PAD_L + (plot_w / 2 if n == 1 else plot_w * i / (n - 1))

    # legend, always present for two series; the end labels repeat identity in text
    lx = PAD_L
    for p in gr.ORDER:
        o.append('<circle cx="%.1f" cy="20" r="5" fill="%s"/>' % (lx + 5, th["series"][p]))
        o.append('<text x="%.1f" y="24" font-size="12" fill="%s">%s</text>'
                 % (lx + 15, th["ink2"], gr.esc(gr.LABEL_BY_LOC[loc][p])))
        lx += 30 + 7.6 * len(gr.LABEL_BY_LOC[loc][p])

    live = [i for i, (f, st_, _t, _u) in enumerate(PANELS)
            if any(f in daily.get((d, p), {}) for d in days for p in gr.ORDER)]
    for pi, (field, stat, _zh_title, unit) in enumerate(PANELS):
        if pi not in live:
            continue
        title = TITLES[loc][pi]
        top = PAD_T + live.index(pi) * (PH + GAP)
        vals = [daily[(d, p)][field][stat]
                for d in days for p in gr.ORDER
                if (d, p) in daily and field in daily[(d, p)]]
        hi = ceiling(max(vals) * 1.04) if vals else 1

        def Y(v, _top=top, _hi=hi):
            return _top + PH - (PH * min(v, _hi) / _hi)

        o.append('<text x="%d" y="%.1f" font-size="13" font-weight="600" fill="%s">%s</text>'
                 % (PAD_L, top - 11, th["ink"], gr.esc("%s（%s）" % (title, unit))))
        for k in range(3):
            v = hi * k / 2.0
            y = Y(v)
            o.append('<line x1="%d" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="1"/>'
                     % (PAD_L, y, W - PAD_R, y, th["grid"]))
            o.append('<text x="%d" y="%.1f" font-size="11" text-anchor="end" fill="%s">%s</text>'
                     % (PAD_L - 8, y + 4, th["ink3"], "%g" % v))

        ends = []
        for p in gr.ORDER:
            pts = [(i, daily[(d, p)][field][stat]) for i, d in enumerate(days)
                   if (d, p) in daily and field in daily[(d, p)]]
            if not pts:
                continue
            col = th["series"][p]
            if len(pts) > 1:
                o.append('<polyline fill="none" stroke="%s" stroke-width="2" '
                         'stroke-linejoin="round" points="%s"/>'
                         % (col, " ".join("%.1f,%.1f" % (X(i), Y(v)) for i, v in pts)))
            # markers always drawn: with two or three days a bare line is unreadable
            for i, v in pts:
                o.append('<circle cx="%.1f" cy="%.1f" r="4.5" fill="%s" stroke="%s" '
                         'stroke-width="2"/>' % (X(i), Y(v), col, th["surface"]))
            # Jitter lives below 1 ms, where "%.0f" prints "0 ms" and "1 ms" and the
            # panel loses its point entirely. Scale the precision to the magnitude.
            val = pts[-1][1]
            if abs(val) >= 10:
                txt = "%.0f" % val
            else:
                # trailing zeros are noise: 3.00 should read "3", 0.80 should read "0.8"
                txt = ("%.2f" % val).rstrip("0").rstrip(".")
            ends.append([Y(val), col, "%s %s" % (txt, unit)])

        # direct end labels, nudged apart so two close series do not overprint
        ends.sort()
        if len(ends) == 2 and ends[1][0] - ends[0][0] < 13:
            ends[0][0] -= (13 - (ends[1][0] - ends[0][0])) / 2.0
            ends[1][0] = ends[0][0] + 13
        for y, col, txt in ends:
            o.append('<text x="%.1f" y="%.1f" font-size="12" font-weight="600" fill="%s">%s</text>'
                     % (W - PAD_R + 8, y + 4, col, txt))

        # x labels on the last panel only -- one shared axis, never one per panel
        if pi == live[-1]:
            step = max(1, (n + 7) // 8)
            for i, d in enumerate(days):
                if i % step and i != n - 1:
                    continue
                o.append('<text x="%.1f" y="%.1f" font-size="11" text-anchor="middle" '
                         'fill="%s">%s</text>'
                         % (X(i), top + PH + 18, th["ink3"], d.strftime("%m/%d")))

    o.append('<text x="%d" y="%d" font-size="11" fill="%s">%s</text>'
             % (PAD_L, H - 8, th["ink3"],
                gr.esc(CAPTION[loc] % datetime.datetime.now().strftime("%Y-%m-%d %H:%M"))))
    o.append("</svg>")
    open(path_out, "w", encoding="utf-8").write("\n".join(o))


def main():
    rows = gr.load(SRC)
    if not rows:
        print("no rows in %s" % SRC)
        return 1
    daily = rollup(rows)
    if not daily:
        print("no day reached MIN_SAMPLES=%d yet" % MIN_SAMPLES)
        return 1
    os.makedirs(OUT, exist_ok=True)
    days = write_csv(daily, os.path.join(OUT, "history.csv"))
    days = days[-MAX_DAYS:]
    for loc in gr.LOCALES:
        for name in ("light", "dark"):
            svg(daily, days, name,
                os.path.join(OUT, "history-%s%s.svg" % (name, gr.suffix(loc))), loc)
    print("history: %d days rendered, %d day/path groups" % (len(days), len(daily)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
