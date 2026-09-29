#!/bin/zsh
# make-remote-fixture.sh <dir> — the Fetch/Pull/Push UI fixture (#0455).
#
# Run inside the Tart guest by scripts/run-ui-tests-vm.sh; never shared,
# never host-live, NEVER the network: the remote is a bare repository in
# <dir>, reached by path (guide §11 decision 32). Four clones of it, one per
# spike, each on branch `remote-main` with upstream `origin/remote-main`:
#
#   pull-repo       cloned, then another writer pushed "0457 remote commit":
#                   up to date until Fetch, then 1 behind (#0457 fetch-pull)
#   diverged-repo   the same, plus a local "0457 local commit": after Pull's
#                   fetch it is 1 ahead, 1 behind (#0457 refused)
#   push-repo       on a new branch `push-feature` with "0459 pushed commit"
#                   and no upstream (#0459)
#   slow-push-repo  1 ahead with "0458 slow commit" and a pre-push hook that
#                   sleeps 300 s (#0458)
set -euo pipefail
dir="$1"
mkdir -p "$dir"
cd "$dir"
export GIT_CONFIG_NOSYSTEM=1
id=(-c user.email=uitest@example.invalid -c 'user.name=Switchyard UI Test' -c commit.gpgsign=false)

git init -q --bare --initial-branch=remote-main remote.git
git clone -q remote.git seed 2>/dev/null
git -C seed "${id[@]}" commit -q --allow-empty -m 'remote base commit'
git -C seed push -q origin HEAD:refs/heads/remote-main

clone() {
  git clone -q remote.git "$1"
  git -C "$1" config user.email uitest@example.invalid
  git -C "$1" config user.name 'Switchyard UI Test'
  git -C "$1" config commit.gpgsign false
}
clone pull-repo
clone diverged-repo
clone push-repo
clone slow-push-repo

# Another machine pushes after pull-repo and diverged-repo were cloned.
printf 'remote\n' > seed/remote.txt
git -C seed add remote.txt
git -C seed "${id[@]}" commit -q -m '0457 remote commit'
git -C seed push -q origin HEAD:refs/heads/remote-main
rm -rf seed

printf 'local\n' > diverged-repo/local.txt
git -C diverged-repo add local.txt
git -C diverged-repo commit -q -m '0457 local commit'

git -C push-repo switch -q -c push-feature
printf 'pushed\n' > push-repo/pushed.txt
git -C push-repo add pushed.txt
git -C push-repo commit -q -m '0459 pushed commit'

git -C slow-push-repo pull -q --ff-only
printf 'slow\n' > slow-push-repo/slow.txt
git -C slow-push-repo add slow.txt
git -C slow-push-repo commit -q -m '0458 slow commit'
hooks="$(git -C slow-push-repo rev-parse --path-format=absolute --git-path hooks)"
mkdir -p "$hooks"
printf '#!/bin/sh\nsleep 300\n' > "$hooks/pre-push"
chmod +x "$hooks/pre-push"
