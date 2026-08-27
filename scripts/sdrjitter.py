#!/usr/bin/env python3
"""High-rate paired jitter probe against a Valve SDR relay.

sdrping.py sends one packet, waits for the reply, then sleeps -- so its rate is coupled to
the RTT and it cannot see anything faster than about 8 samples a second. What a player feels
in CS2 happens between those samples. This sends at a fixed wall-clock rate and collects
replies asynchronously, so the output is a per-packet series at game-like cadence.

The relay's reply carries no correlation id (it is a fixed "Invalid/unknown MsgID" error),
so each probe gets its own ephemeral socket and replies are matched by which socket they
arrive on. That is exact, and at 10 pps with a 1 s timeout only ~10 sockets are ever live.

Traffic: 32 B payload + 8 UDP + 20 IP + 14 Ethernet = 74 B on the wire.
At 10 pps that is 740 B/s -- 0.0002% of a 300 Mbit line, per path.

Usage: sdrjitter.py <src_ip> <dst_ip> <dport> <pps> <seconds> <label>
"""
import selectors
import socket
import statistics as st
import sys
import time

src, dst = sys.argv[1], sys.argv[2]
dport = int(sys.argv[3])
pps = float(sys.argv[4])
secs = float(sys.argv[5])
label = sys.argv[6] if len(sys.argv) > 6 else src

TIMEOUT = 1.0
interval = 1.0 / pps
sel = selectors.DefaultSelector()
inflight = {}           # fileno -> (seq, sent_at, sock)
rtts = []               # (seq, rtt_ms)
lost = []
t_start = time.time()
next_send = t_start
seq = 0

while True:
    now = time.time()
    if now - t_start >= secs and not inflight:
        break

    # send on schedule
    if now >= next_send and now - t_start < secs:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setblocking(False)
            s.bind((src, 0))
            s.sendto(b"\x00" * 32, (dst, dport))
            sel.register(s, selectors.EVENT_READ)
            inflight[s.fileno()] = (seq, time.time(), s)
        except Exception:
            lost.append(seq)
        seq += 1
        next_send += interval
        # if we fell behind, do not try to catch up in a burst
        if next_send < now:
            next_send = now + interval

    # collect whatever has come back
    for key, _ in sel.select(timeout=0.002):
        fd = key.fd
        rec = inflight.pop(fd, None)
        if rec is None:
            continue
        q, sent, s = rec
        try:
            s.recv(512)
            rtts.append((q, (time.time() - sent) * 1000.0))
        except Exception:
            lost.append(q)
        sel.unregister(s)
        s.close()

    # expire
    now = time.time()
    for fd in [fd for fd, (_, sent, _) in inflight.items() if now - sent > TIMEOUT]:
        q, sent, s = inflight.pop(fd)
        lost.append(q)
        sel.unregister(s)
        s.close()

sel.close()
rtts.sort()
v = [r for _, r in rtts]
total = seq
nlost = len(lost)

if not v:
    print("%s,SENT=%d,REPLIES=0,NOREPLY=100.0%%" % (label, total))
    sys.exit(0)


def q(p):
    return sorted(v)[min(len(v) - 1, int(len(v) * p))]


# consecutive no-reply runs: one long run is a stall, many singles are ordinary
# relay rate-limiting and is not something a player would notice.
lost_set = set(lost)
runs, cur = [], 0
for i in range(total):
    if i in lost_set:
        cur += 1
    elif cur:
        runs.append(cur)
        cur = 0
if cur:
    runs.append(cur)

# jitter as consecutive-difference (what a game actually experiences)
deltas = [abs(v[i] - v[i - 1]) for i in range(1, len(v))]

print("%s" % label)
print("  sent=%d  replies=%d  no-reply=%.1f%%" % (total, len(v), nlost / total * 100))
print("  rtt   min=%.1f  med=%.1f  p95=%.1f  p99=%.1f  max=%.1f  (ms)"
      % (min(v), st.median(v), q(0.95), q(0.99), max(v)))
print("  jitter  mean|delta|=%.2f  p95|delta|=%.2f  max|delta|=%.1f  stdev=%.2f  (ms)"
      % (st.mean(deltas) if deltas else 0,
         sorted(deltas)[min(len(deltas) - 1, int(len(deltas) * 0.95))] if deltas else 0,
         max(deltas) if deltas else 0,
         st.pstdev(v)))
print("  no-reply runs: count=%d  longest=%d consecutive (%.2f s of silence)"
      % (len(runs), max(runs) if runs else 0, (max(runs) if runs else 0) * interval))
print("  spikes >2x median: %d   >100 ms: %d"
      % (sum(1 for x in v if x > 2 * st.median(v)), sum(1 for x in v if x > 100)))
