#!/bin/bash
# Regenerate the published artefacts from the live probe and push them.
#
# Runs on the probe host under a timer. Authentication is a repo-scoped deploy key,
# not a personal access token: if this box is compromised the blast radius is one
# public repository, not the whole GitHub account.
#
# Failures are reported to the external Cloudflare watchdog through job-alert.sh, under
# the source name "probe-publish". A unit failure already shows up in systemctl --failed
# and so reaches the heartbeat, but only as an anonymous "the box is degraded" that then
# holds that channel down; a named alert says which job broke and leaves the dead-man
# switch free to report the next real fault. Transient network trouble uses soft-fail, so
# one lost fetch on an hourly timer stays silent and only the second in a row mails.
set -uo pipefail

REPO=${REPO_DIR:-/root/pi-probe-repo}
CSV=${CSV_PATH:-/root/netmeasure/paired.csv}
KEY=${DEPLOY_KEY:-/root/.ssh/id_probe_publish}

export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

ALERT=${ALERT_CMD:-/usr/local/sbin/job-alert.sh}
alert() { [ -x "$ALERT" ] && "$ALERT" probe-publish "$@" >/dev/null 2>&1 || true; }

cd "$REPO" || { echo "no repo at $REPO"; alert fail "no repo at $REPO"; exit 1; }

# The timer and a manual run WILL collide otherwise: two publishes racing produced a
# stale index.lock and a rejected push the first time this ran. Non-blocking, so the
# loser simply skips this cycle rather than queueing up behind the winner.
exec 9>/run/probe-publish.lock
flock -n 9 || { echo "$(date -Is) another publish in flight, skipping"; exit 0; }
[ -s "$CSV" ] || { echo "no probe data at $CSV"; alert fail "no probe data at $CSV"; exit 1; }

# Every file this script commits is regenerated from the CSV two lines below, so there
# is never anything local worth preserving. Taking the remote wholesale means prose edited
# from the web UI always survives, and an unattended timer can never wedge on a conflict.
# (The previous version passed -X ours, which did the opposite of what its comment claimed,
# and fell back to a hard reset that could only lose work.)
if ! git fetch --quiet origin main; then
  echo "$(date -Is) fetch failed, skipping this cycle"
  # Transient by nature -- the next hourly run is the retry. Escalates only if that one
  # fails too, so a single blip never mails.
  alert soft-fail "git fetch origin main failed"
  exit 0
fi
git checkout --quiet main
git reset --hard --quiet origin/main

python3 "$REPO/tools/gen_report.py" "$CSV" "$REPO/data" || { alert fail "gen_report.py failed"; exit 1; }

# The main chart is a rolling 48-hour window, so a quiet day changes nothing visible and
# this script commits nothing at all. The daily rollup gains a row every day and keeps
# moving the current day's row, so the history is always readable in the diff.
python3 "$REPO/tools/gen_history.py" "$CSV" "$REPO/data" || { alert fail "gen_history.py failed"; exit 1; }

git add -A data/
if git diff --cached --quiet; then
  echo "$(date -Is) nothing changed"
  # A quiet cycle is a healthy cycle: it must clear an outstanding alert, or one bad hour
  # would stay outstanding until the data happened to change again.
  alert ok "nothing to publish"
  exit 0
fi

ROWS=$(( $(wc -l < "$CSV") - 1 ))
git -c user.name="probe" -c user.email="probe@localhost" \
    commit --quiet -m "data: refresh from live probe ($ROWS samples)"

if git push --quiet origin main; then
  echo "$(date -Is) pushed ($ROWS samples)"
  alert ok "pushed $ROWS samples"
else
  echo "$(date -Is) push FAILED"
  alert fail "git push origin main was rejected ($ROWS samples pending)"
  exit 1
fi
