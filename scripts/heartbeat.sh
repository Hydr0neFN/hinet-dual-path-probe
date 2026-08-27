#!/bin/bash
# External dead-man switch.
#
# Every alert this box can raise goes through Home Assistant, which means a total
# failure -- kernel wedge, dead SD card, power cut, network gone -- raises nothing at
# all. This flips the direction: the Pi calls OUT on a schedule, and an external
# service emails the owner when the calls stop.
#
# /etc/heartbeat.url holds ONE URL PER LINE. They are equivalent endpoints for the same
# Worker; the extra lines exist only so that a DNS problem, an expired domain or a
# network that blanket-blocks one hostname cannot silence the alarm. The first one that
# accepts the ping wins. Without the file this script exits 0 and does nothing, so it is
# safe to enable before any of it is set up.
set -uo pipefail

URLFILE=/etc/heartbeat.url
[ -r "$URLFILE" ] || exit 0
URLS=$(tr -d '\r' < "$URLFILE" | grep -E '^https?://')
[ -n "$URLS" ] || exit 0

# Compact health summary, sent as the ping body so the dashboard shows why, not just when.
ROOTSRC=$(findmnt -n -o SOURCE / 2>/dev/null)
SSD=$(mountpoint -q /mnt/ssd && echo up || echo DOWN)
QBT=$(systemctl is-active qbittorrent 2>/dev/null)
HA=$(curl -s -o /dev/null -m 8 -w '%{http_code}' http://127.0.0.1:8123/ 2>/dev/null)
FAILED=$(systemctl --failed --no-legend --no-pager 2>/dev/null | wc -l)
ROOTPCT=$(df --output=pcent / 2>/dev/null | tail -1 | tr -d ' %')
# grep -c prints 0 AND exits 1 when there are no matches, so a || fallback would print a
# second zero on top of it and make this two lines instead of one.
RECOV=$(grep -c 'recovery complete' /var/lib/ssd-recover.log 2>/dev/null)
RECOV=${RECOV:-0}
UP=$(uptime -p 2>/dev/null)

BODY="root=$ROOTSRC ssd=$SSD qbt=$QBT ha_http=$HA failed_units=$FAILED root_used=${ROOTPCT}% ssd_recoveries=$RECOV $UP"

# Report a failure state to the monitor when something is actually wrong, so the
# owner hears about degradation, not only about total silence.
SUFFIX=""
[ "$FAILED" -gt 0 ] 2>/dev/null && SUFFIX="/fail"
case "$HA" in 200|30[123]|401) : ;; *) SUFFIX="/fail" ;; esac
[ "${ROOTPCT:-0}" -ge 90 ] 2>/dev/null && SUFFIX="/fail"

# The URL carries ?token=..., so appending /fail to the whole string would put the suffix
# inside the query value: the token stops matching and every degraded ping 403s. The
# suffix has to go into the PATH, before the query string.
sent=0
for URL in $URLS; do
  case "$URL" in
    *\?*) TARGET="${URL%%\?*}${SUFFIX}?${URL#*\?}" ;;
    *)    TARGET="${URL}${SUFFIX}" ;;
  esac
  if curl -fsS -m 20 --retry 2 --retry-delay 3 --data-raw "$BODY" "$TARGET" >/dev/null 2>&1; then
    sent=1
    break
  fi
done

if [ "$sent" -eq 0 ]; then
  logger -t heartbeat "no heartbeat endpoint accepted the ping"
fi
exit 0
