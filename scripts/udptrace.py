#!/usr/bin/env python3
"""UDP-path traceroute. Forward probes are UDP to the game's destination port,
so they hash into the same ECMP bucket as CS2 traffic. Replies are ICMP
time-exceeded, matched back to the probe by its source port.
Usage: udptrace.py <src_ip> <dest_ip> [dport] [maxttl] [probes_per_hop]"""
import socket, struct, sys, time, select

def probe(src, dst, dport, ttl, sport, timeout=1.5):
    rx = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 16)
    rx.bind((src, 0))
    rx.setblocking(False)
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    tx.setsockopt(socket.IPPROTO_IP, socket.IP_TTL, ttl)
    tx.bind((src, sport))
    t0 = time.time()
    try:
        tx.sendto(b"\x00" * 32, (dst, dport))
    except OSError as e:
        rx.close(); tx.close(); return None, None, f"send:{e}"
    deadline = t0 + timeout
    try:
        while True:
            left = deadline - time.time()
            if left <= 0:
                return None, None, None
            r, _, _ = select.select([rx], [], [], left)
            if not r:
                return None, None, None
            pkt, addr = rx.recvfrom(1024)
            rtt = (time.time() - t0) * 1000
            ihl = (pkt[0] & 0x0F) * 4
            icmp = pkt[ihl:]
            if len(icmp) < 8:
                continue
            itype = icmp[0]
            if itype not in (11, 3):
                continue
            inner = icmp[8:]
            if len(inner) < 20:
                continue
            iihl = (inner[0] & 0x0F) * 4
            udp = inner[iihl:iihl + 8]
            if len(udp) < 4:
                continue
            osp, odp = struct.unpack("!HH", udp[:4])
            if osp != sport or odp != dport:
                continue
            return addr[0], rtt, ("unreach" if itype == 3 else "ttl")
    finally:
        rx.close(); tx.close()

def main():
    src, dst = sys.argv[1], sys.argv[2]
    dport = int(sys.argv[3]) if len(sys.argv) > 3 else 27023
    maxttl = int(sys.argv[4]) if len(sys.argv) > 4 else 20
    n = int(sys.argv[5]) if len(sys.argv) > 5 else 3
    sport = 33500
    print(f"UDP trace {src} -> {dst}:{dport}  (probes={n})")
    for ttl in range(1, maxttl + 1):
        ips, rtts = [], []
        for _ in range(n):
            sport = 33500 + (sport - 33500 + 1) % 2000
            ip, rtt, kind = probe(src, dst, dport, ttl, sport)
            if ip:
                ips.append(ip); rtts.append(rtt)
        if not ips:
            print(f"{ttl:2d}  *")
            continue
        uniq = sorted(set(ips))
        avg = sum(rtts) / len(rtts)
        loss = 100 * (n - len(rtts)) // n
        tag = " <<< DEST" if dst in uniq else ""
        print(f"{ttl:2d}  {','.join(uniq):<24} {avg:6.1f}ms  loss={loss:3d}%{tag}")
        if dst in uniq:
            return
main()
