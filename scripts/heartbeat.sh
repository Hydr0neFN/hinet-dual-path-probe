#!/bin/bash
# External dead-man switch.
#
# Every alert this box can raise goes through Home Assistant, which means a total
# failure -- kernel wedge, dead SD card, power cut, network gone -- raises nothing at
# all. This flips the direction: the Pi calls OUT on a schedule, and an external
# service emails the owner when the calls stop.
#
# Put the ping URL (e.g. a https://hc-ping.com/<uuid> from healthchecks.io) in
# /etc/heartbeat.url. Without that file this script does nothing and exits clean,
# so it is safe to enable before the URL exists.
set -uo pipefail

URLFILE=/etc/heartbeat.url
[ -r "$URLFILE" ] || exit 0
URL=$(head -1 "$URLFILE" | tr -d '[:space:]')
case "$URL" in
  https://*|http://*) : ;;
  *) exit 0 ;;
esac

# Compact health summary, sent as the ping body so the dashboard shows why, not just when.
ROOTSRC=$(findmnt -n -o SOURCE / 2>/dev/null)
SSD=$(mountpoint -q /mnt/ssd && echo up || echo DOWN)
QBT=$(systemctl is-active qbittorrent 2>/dev/null)
HA=$(curl -s -o /dev/null -m 8 -w '%{http_code}' http://127.0.0.1:8123/ 2>/dev/null)
FAILED=$(systemctl --failed --no-legend --no-pager 2>/dev/null | wc -l)
ROOTPCT=$(df --output=pcent / 2>/dev/null | tail -1 | tr -d ' %')
RECOV=$(grep -c 'recovery complete' /var/lib/ssd-recover.log 2>/dev/null || echo 0)
UP=$(uptime -p 2>/dev/null)

BODY="root=$ROOTSRC ssd=$SSD qbt=$QBT ha_http=$HA failed_units=$FAILED root_used=${ROOTPCT}% ssd_recoveries=$RECOV $UP"

# Report a failure state to the monitor when something is actually wrong, so the
# owner hears about degradation, not only about total silence.
SUFFIX=""
[ "$FAILED" -gt 0 ] && SUFFIX="/fail"
case "$HA" in 200|30[123]|401) : ;; *) SUFFIX="/fail" ;; esac
[ "${ROOTPCT:-0}" -ge 90 ] 2>/dev/null && SUFFIX="/fail"

# The URL carries ?token=..., so appending /fail to the whole string puts the suffix
# inside the query value: the token stops matching and every degraded ping 403s.
# Insert the suffix into the PATH, before the query string.
if [ -n "$SUFFIX" ]; then
  case "$URL" in
    *\?*) TARGET="${URL%%\?*}${SUFFIX}?${URL#*\?}" ;;
    *)    TARGET="${URL}${SUFFIX}" ;;
  esac
else
  TARGET="$URL"
fi

curl -fsS -m 20 --retry 3 --retry-delay 5 --data-raw "$BODY" "$TARGET" >/dev/null 2>&1
exit 0
