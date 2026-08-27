#!/bin/bash
# Hand-rolled TTL traceroute. mtr on this Pi returns only hop 1 then all '???'
# in both ICMP and UDP modes, so it is not used. plain ping -t works.
# $1=src $2=target $3=maxttl
for ttl in $(seq 1 "${3:-16}"); do
  L=$(ping -I "$1" -n -c 1 -W 1 -t "$ttl" "$2" 2>&1 | grep icmp_seq | head -1)
  if [ -z "$L" ]; then printf "%2d  *\n" "$ttl"; continue; fi
  IP=$(echo "$L" | grep -oiE '(from )[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $2}')
  T=$(echo "$L" | grep -oE 'time=[0-9.]+' | cut -d= -f2)
  if echo "$L" | grep -q 'Time to live exceeded'; then printf "%2d  %-16s\n" "$ttl" "$IP"
  else printf "%2d  %-16s %sms  <<< DEST\n" "$ttl" "$IP" "${T:-?}"; exit 0; fi
done
