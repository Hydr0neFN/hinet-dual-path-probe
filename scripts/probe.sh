#!/bin/bash
# Paired latency probe: same instant, same host, two ISP sessions.
#   eth0 source  -> default route -> CHT modem  (whatever account the modem dials)
#   ppp0 source  -> table 200     -> Pi's own PPPoE session
CSV=/root/netmeasure/paired.csv
MTRDIR=/root/netmeasure/mtr
mkdir -p "$MTRDIR"
TOKYO=45.121.184.27
CF=1.1.1.1
GOOG=8.8.8.8
LAST_MTR=0

[ -f "$CSV" ] || echo "ts,path,src,tokyo_avg,tokyo_loss,cf_avg,cf_loss,goog_avg,goog_loss,sdr_udp_rtt" > "$CSV"

probe() { # $1=src ip  $2=target -> "avg,loss"
  local out avg loss
  out=$(ping -I "$1" -n -c 5 -W 2 -i 0.3 "$2" 2>/dev/null)
  loss=$(echo "$out" | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+')
  avg=$(echo "$out"  | awk -F'/' '/^rtt|^round-trip/ {printf "%.0f", $5}')
  [ -z "$loss" ] && loss=100
  [ -z "$avg" ]  && avg=-1
  echo "$avg,$loss"
}

while true; do
  TS=$(date '+%Y-%m-%d %H:%M:%S')
  ETH=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)
  PPP=$(ip -4 -o addr show ppp0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  DEGRADED=0
  # Both paths are sampled CONCURRENTLY. Run one after the other, each takes 8.6-10.4 s,
  # so the second path was measured ~9 s after the first while both rows carried the
  # loop-start timestamp -- the comparison looked simultaneous and was not. Whatever
  # transient hits the line now hits both paths together, which is the whole point.
  TMP=$(mktemp -d)
  for pair in "modem:$ETH" "pppoe:$PPP"; do
    NAME=${pair%%:*}; SRC=${pair#*:}
    (
      if [ -z "$SRC" ]; then
        echo "$TS,$NAME,DOWN,-1,100,-1,100,-1,100,-1" > "$TMP/$NAME"
        exit 0
      fi
      T=$(probe "$SRC" "$TOKYO"); C=$(probe "$SRC" "$CF"); G=$(probe "$SRC" "$GOOG")
      # End-to-end UDP RTT to the relay's game port -- the transport CS2 actually uses.
      # RTT only: the relay answers junk datagrams non-deterministically (16-33% no-reply
      # at every inter-packet gap tested), so its loss figure is meaningless. ICMP owns loss.
      SDR=$(timeout 20 python3 /root/netmeasure/sdrping.py "$SRC" "$TOKYO" 27023 8 2>/dev/null | cut -d, -f1)
      [ -z "$SDR" ] && SDR=-1
      echo "$TS,$NAME,$SRC,$T,$C,$G,$SDR" > "$TMP/$NAME"
    ) &
  done
  wait

  for NAME in modem pppoe; do
    [ -s "$TMP/$NAME" ] || { DEGRADED=1; continue; }
    LINE=$(cat "$TMP/$NAME")
    echo "$LINE" >> "$CSV"
    TA=$(echo "$LINE" | cut -d, -f4)
    TL=$(echo "$LINE" | cut -d, -f5)
    CA=$(echo "$LINE" | cut -d, -f6)
    SDR=$(echo "$LINE" | cut -d, -f10)
    [ "$TA" -gt 60 ] 2>/dev/null && DEGRADED=1
    [ "$TL" -gt 0 ]  2>/dev/null && DEGRADED=1
    [ "$CA" -gt 50 ] 2>/dev/null && DEGRADED=1
    [ "$SDR" -gt 60 ] 2>/dev/null && DEGRADED=1
    # -1 means the relay answered nothing at all: worse than slow, not "less than 60".
    [ "$SDR" -lt 0 ] 2>/dev/null && DEGRADED=1
  done
  rm -rf "$TMP"
  NOW=$(date +%s)
  # Captures run detached: a synchronous trace blocked the sampling loop for ~3.4 min,
  # so the probe stopped measuring exactly during the degradation it was recording.
  if [ "$DEGRADED" = "1" ] && [ $((NOW-LAST_MTR)) -gt 300 ] && ! pgrep -f hoptrace.sh >/dev/null 2>&1; then
    LAST_MTR=$NOW
    STAMP=$(date '+%Y%m%d-%H%M%S')
    { for pair in "modem:$ETH" "pppoe:$PPP"; do
        NAME=${pair%%:*}; SRC=${pair#*:}; [ -z "$SRC" ] && continue
        for TGT in $TOKYO $CF; do
          echo "===== $NAME src=$SRC -> $TGT ====="
          /root/netmeasure/hoptrace.sh "$SRC" "$TGT" 16
          echo "----- UDP path (dport 27023, ECMP-matched) -----"
          timeout 90 python3 /root/netmeasure/udptrace.py "$SRC" "$TGT" 27023 18 2 2>&1
        done
      done; } > "$MTRDIR/$STAMP.txt" &
  fi
  sleep 25
done
