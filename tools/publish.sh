#!/bin/bash
# Regenerate the published artefacts from the live probe and push them.
#
# Runs on the probe host under a timer. Authentication is a repo-scoped deploy key,
# not a personal access token: if this box is compromised the blast radius is one
# public repository, not the whole GitHub account.
set -uo pipefail

REPO=${REPO_DIR:-/root/pi-probe-repo}
CSV=${CSV_PATH:-/root/netmeasure/paired.csv}
KEY=${DEPLOY_KEY:-/root/.ssh/id_probe_publish}

export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

cd "$REPO" || { echo "no repo at $REPO"; exit 1; }

# The timer and a manual run WILL collide otherwise: two publishes racing produced a
# stale index.lock and a rejected push the first time this ran. Non-blocking, so the
# loser simply skips this cycle rather than queueing up behind the winner.
exec 9>/run/probe-publish.lock
flock -n 9 || { echo "$(date -Is) another publish in flight, skipping"; exit 0; }
[ -s "$CSV" ] || { echo "no probe data at $CSV"; exit 1; }

# Every file this script commits is regenerated from the CSV two lines below, so there
# is never anything local worth preserving. Taking the remote wholesale means prose edited
# from the web UI always survives, and an unattended timer can never wedge on a conflict.
# (The previous version passed -X ours, which did the opposite of what its comment claimed,
# and fell back to a hard reset that could only lose work.)
if ! git fetch --quiet origin main; then
  echo "$(date -Is) fetch failed, skipping this cycle"
  exit 0
fi
git checkout --quiet main
git reset --hard --quiet origin/main

python3 "$REPO/tools/gen_report.py" "$CSV" "$REPO/data" || exit 1

git add -A data/
if git diff --cached --quiet; then
  echo "$(date -Is) nothing changed"
  exit 0
fi

ROWS=$(( $(wc -l < "$CSV") - 1 ))
git -c user.name="probe" -c user.email="probe@localhost" \
    commit --quiet -m "data: refresh from live probe ($ROWS samples)"

if git push --quiet origin main; then
  echo "$(date -Is) pushed ($ROWS samples)"
else
  echo "$(date -Is) push FAILED"
  exit 1
fi
