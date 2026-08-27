#!/usr/bin/env python3
"""End-to-end UDP RTT to a Valve SDR relay.
The relay replies 'Invalid/unknown MsgID' to a junk datagram on its game port,
so this measures the REAL transport CS2 uses: same protocol, same dest port,
same 5-tuple class -> same ECMP bucket. Prints 'avg,loss' for scripting.
Usage: sdrping.py <src_ip> <dst_ip> [dport] [count]"""
import socket, sys, time

src, dst = sys.argv[1], sys.argv[2]
dport = int(sys.argv[3]) if len(sys.argv) > 3 else 27023
count = int(sys.argv[4]) if len(sys.argv) > 4 else 10
rtts = []
for i in range(count):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.5)
    try:
        s.bind((src, 0))
        t0 = time.time()
        s.sendto(b"\x00" * 32, (dst, dport))
        s.recvfrom(512)
        rtts.append((time.time() - t0) * 1000)
    except Exception:
        pass
    finally:
        s.close()
    time.sleep(0.12)
loss = 100 * (count - len(rtts)) // count
avg = sum(rtts) / len(rtts) if rtts else -1
print(f"{avg:.0f},{loss}")
