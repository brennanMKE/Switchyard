#!/bin/zsh
# make-remotes-fixture.sh <dir> — the remote-management UI fixture (guide §11
# decision 41).
#
# Run inside the Tart guest by scripts/run-ui-tests-vm.sh; never shared,
# never host-live, NEVER the network: both remotes are bare repositories in
# <dir>, reached by path.
#
#   origin.git   branches remotes-main and (deleted after the clone)
#                stale-topic
#   backup.git   one branch, backup-only — not configured anywhere; the
#                spike adds it with Add Remote…
#   repo         a clone of origin.git on remotes-main (upstream
#                origin/remotes-main) that still has origin/stale-topic, so
#                Prune “origin” has something to delete
set -euo pipefail
dir="$1"
mkdir -p "$dir"
cd "$dir"
export GIT_CONFIG_NOSYSTEM=1
id=(-c user.email=uitest@example.invalid -c 'user.name=Switchyard UI Test' -c commit.gpgsign=false)

git init -q --bare --initial-branch=remotes-main origin.git
git init -q --bare --initial-branch=backup-only backup.git
git clone -q origin.git seed 2>/dev/null
git -C seed "${id[@]}" commit -q --allow-empty -m 'remotes base commit'
git -C seed push -q origin HEAD:refs/heads/remotes-main HEAD:refs/heads/stale-topic
git -C seed push -q "$dir/backup.git" HEAD:refs/heads/backup-only
rm -rf seed

git clone -q origin.git repo 2>/dev/null
git -C repo config user.email uitest@example.invalid
git -C repo config user.name 'Switchyard UI Test'
git -C repo config commit.gpgsign false
git -C origin.git update-ref -d refs/heads/stale-topic
