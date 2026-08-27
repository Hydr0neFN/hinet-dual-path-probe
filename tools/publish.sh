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
[ -s "$CSV" ] || { echo "no probe data at $CSV"; exit 1; }

# Someone may have edited the prose from the web UI. Take theirs, keep ours for the
# generated files, and never let a conflict wedge an unattended timer.
git fetch --quiet origin main || true
git checkout --quiet main
git merge --quiet -X ours --no-edit origin/main 2>/dev/null || git reset --hard --quiet origin/main

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
