# Results

Full dataset: `2026-08-26 11:55:50` → `2026-08-28 00:24:02` · **3315 samples** (`1658` per path)

> These tables cover **every** sample ever recorded; the chart in the README shows only the last 48 hours, so the two drift apart as time goes on.

Both paths are measured from the same host in the same loop iteration, so a difference comes from the path and not from when it was taken. (Samples before `2026-08-27 21:02` were taken one after the other, about 9 s apart -- see the README.)

| Metric | Static median | Static p95 | Dynamic median | Dynamic p95 |
|---|---|---|---|---|
| Tokyo SDR relay, UDP RTT (ms) | 34 | 40 | 34 | 45 |
| Tokyo SDR relay, ICMP RTT (ms) | 34 | 40 | 34 | 50 |
| Cloudflare 1.1.1.1 RTT (ms) | 3 | 3 | 24 | 209 |
| Google 8.8.8.8 RTT (ms) | 2 | 3 | 2 | 13 |

## Paired difference (dynamic minus static, same loop iteration)

| Metric | Median | p95 | Share of samples where dynamic is >5 ms worse |
|---|---|---|---|
| Tokyo SDR relay, UDP RTT | +0 ms | +6 ms | 5.8% |
| Tokyo SDR relay, ICMP RTT | +0 ms | +10 ms | 8.3% |
| Cloudflare 1.1.1.1 RTT | +21 ms | +206 ms | 86.7% |
| Google 8.8.8.8 RTT | +0 ms | +11 ms | 7.4% |

_Regenerated automatically by the running probe. Last updated: 2026-08-28 00:25 (UTC+8)._
