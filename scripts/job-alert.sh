#!/bin/bash
# Report a named unattended job's health to the external Cloudflare watchdog.
#
#   job-alert.sh <source> fail       "message"   deterministic failure -> mail at once
#   job-alert.sh <source> soft-fail  "message"   transient failure -> mail on the 2nd in a row
#   job-alert.sh <source> ok                     healthy -> clears an outstanding alert
#
# This is deliberately NOT the heartbeat. /beat is a dead-man switch with one slot that
# heartbeat.sh overwrites every 5 minutes; a job that pushes its own failure in there gets
# its message erased, makes a healthy box read as degraded, and -- because /beat/fail is
# edge-triggered -- holds the degraded state so that a later real fault produces no change
# in the signal and therefore no mail. /alert has its own key per source and dedupes there,
# so the first failure mails, repeats stay silent, and recovery mails once.
#
# soft-fail exists for the standing rule that a failure which was automatically repaired is
# a non-event: one lost fetch on an hourly timer is noise, two in a row is a real outage.
#
# Endpoints come from /etc/heartbeat.url, one per line, tried in order -- same failover as
# heartbeat.sh, so a dead hostname cannot silence this either. Without that file this exits
# 0 and does nothing.
set -uo pipefail

SOURCE=${1:-}
ACTION=${2:-}
MESSAGE=${3:-}
URLFILE=/etc/heartbeat.url
STATEDIR=/run/job-alert

[ -n "$SOURCE" ] && [ -n "$ACTION" ] || { echo "usage: job-alert.sh <source> fail|soft-fail|ok [message]" >&2; exit 2; }
[ -r "$URLFILE" ] || exit 0
URLS=$(tr -d '\r' < "$URLFILE" | grep -E '^https?://')
[ -n "$URLS" ] || exit 0

mkdir -p "$STATEDIR"
COUNTFILE="$STATEDIR/$SOURCE.count"

case "$ACTION" in
  ok)        SUBPATH="/alert/clear"; rm -f "$COUNTFILE" ;;
  fail)      SUBPATH="/alert" ;;
  soft-fail)
    n=$(( $(cat "$COUNTFILE" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$COUNTFILE"
    # First transient failure is a non-event: the next run is the retry. Only escalate
    # once that retry has also died.
    [ "$n" -ge 2 ] || exit 0
    SUBPATH="/alert"
    MESSAGE="$MESSAGE (consecutive failures: $n)"
    ;;
  *) echo "unknown action: $ACTION" >&2; exit 2 ;;
esac

# The URL already carries ?token=..., so the extra path has to be spliced in BEFORE the
# query string -- appending it to the whole string would bury the suffix inside the token
# value and every call would 403.
for URL in $URLS; do
  BASE="${URL%%/beat*}"
  case "$URL" in
    *\?*) TARGET="${BASE}${SUBPATH}?${URL#*\?}" ;;
    *)    TARGET="${BASE}${SUBPATH}" ;;
  esac
  TARGET="${TARGET}&source=${SOURCE}"
  if curl -fsS -m 20 --retry 2 --retry-delay 3 --data-raw "${MESSAGE:-(no detail)}" "$TARGET" >/dev/null 2>&1; then
    exit 0
  fi
done

logger -t job-alert "no endpoint accepted the $ACTION for $SOURCE"
exit 0
