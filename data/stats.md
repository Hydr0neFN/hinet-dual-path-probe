# Measured results

Whole dataset: `2026-08-26 11:55:50` → `2026-08-27 21:04:09` · **2923 samples** (`1462` per path)

> These tables cover **every** sample ever recorded. The chart in the README shows only the most recent 48 h, so the two will diverge as the run gets longer.

Both paths are measured from the same host, concurrently, in the same loop iteration — so any difference is the path, not the moment. (Samples before 2026-08-27 21:02 were taken sequentially, about 9 s apart; see the README.)

| metric | Static IP median | Static IP p95 | Dynamic IP median | Dynamic IP p95 |
|---|---|---|---|---|
| Tokyo SDR relay, UDP RTT (ms) | 34 | 34 | 33 | 40 |
| Tokyo SDR relay, ICMP RTT (ms) | 34 | 34 | 34 | 44 |
| Cloudflare 1.1.1.1 RTT (ms) | 3 | 3 | 24 | 186 |
| Google 8.8.8.8 RTT (ms) | 2 | 3 | 2 | 14 |

## Paired deltas (dynamic minus static, same loop iteration)

| metric | median | p95 | share of samples where dynamic is worse by >5 ms |
|---|---|---|---|
| Tokyo SDR relay, UDP RTT | +0 ms | +6 ms | 5.6% |
| Tokyo SDR relay, ICMP RTT | +0 ms | +9 ms | 7.5% |
| Cloudflare 1.1.1.1 RTT | +21 ms | +183 ms | 85.0% |
| Google 8.8.8.8 RTT | +0 ms | +12 ms | 7.6% |

_Regenerated automatically from the live probe. Last update: 2026-08-27 21:06 (UTC+8)._
