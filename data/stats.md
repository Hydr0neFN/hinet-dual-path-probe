# Measured results

Window: `2026-08-26 11:55:50` → `2026-08-27 20:57:06` · **2902 samples** (`1451` per path)

Both paths are measured from the same host, in the same loop iteration, microseconds apart — so any difference is the path, not the moment.

| metric | Static IP median | Static IP p95 | Dynamic IP median | Dynamic IP p95 |
|---|---|---|---|---|
| Tokyo SDR relay, UDP RTT (ms) | 34 | 34 | 33 | 40 |
| Tokyo SDR relay, ICMP RTT (ms) | 34 | 34 | 34 | 43 |
| Cloudflare 1.1.1.1 RTT (ms) | 3 | 3 | 24 | 182 |
| Google 8.8.8.8 RTT (ms) | 2 | 3 | 2 | 14 |

## Same-instant deltas (dynamic minus static)

| metric | median | p95 | share of samples where dynamic is worse by >5 ms |
|---|---|---|---|
| Tokyo SDR relay, UDP RTT | +0 ms | +6 ms | 5.7% |
| Tokyo SDR relay, ICMP RTT | +0 ms | +9 ms | 7.5% |
| Cloudflare 1.1.1.1 RTT | +21 ms | +178 ms | 84.9% |
| Google 8.8.8.8 RTT | +0 ms | +12 ms | 7.5% |

_Regenerated automatically from the live probe. Last update: 2026-08-27 20:57 (UTC+8)._
