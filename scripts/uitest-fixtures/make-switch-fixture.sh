#!/bin/zsh
# make-switch-fixture.sh <dir> — the switch / check out / delete UI fixture
# (guide §11 decision 38).
#
# Run inside the Tart guest by scripts/run-ui-tests-vm.sh; never shared,
# never host-live, never the network: the remote is a bare repository in
# <dir>, reached by path. <dir>/repo is a clone on `switch-main`:
#
#   switch-main      "switch base commit" (notes.txt), checked out, and
#                    notes.txt EDITED in the working tree — so switching to
#                    switch-feature is refused until the change is stashed
#   switch-feature   one more commit, "switch feature commit", that changes
#                    notes.txt
#   unmerged-topic   one commit off switch-main, "unmerged topic commit",
#                    on no other branch — Delete asks twice
#   origin/remote-topic  a remote branch with no local branch
#   v-delete-me      a lightweight tag on the base commit
set -euo pipefail
dir="$1"
mkdir -p "$dir"
cd "$dir"
export GIT_CONFIG_NOSYSTEM=1
id=(-c user.email=uitest@example.invalid -c 'user.name=Switchyard UI Test' -c commit.gpgsign=false)

git init -q --bare --initial-branch=switch-main remote.git
git clone -q remote.git repo 2>/dev/null
cd repo
git config user.email uitest@example.invalid
git config user.name 'Switchyard UI Test'
git config commit.gpgsign false
printf 'notes\n' > notes.txt
git add notes.txt
git commit -q -m 'switch base commit'
git push -q origin HEAD:refs/heads/switch-main
git branch -q --set-upstream-to=origin/switch-main

git switch -q -c remote-topic
printf 'remote\n' > remote.txt
git add remote.txt
git commit -q -m 'remote topic commit'
git push -q origin remote-topic
git switch -q switch-main
git branch -q -D remote-topic

git switch -q -c switch-feature
printf 'notes\nfeature line\n' > notes.txt
git commit -q -am 'switch feature commit'
git switch -q switch-main

git switch -q -c unmerged-topic
printf 'topic\n' > topic.txt
git add topic.txt
git commit -q -m 'unmerged topic commit'
git switch -q switch-main

git tag v-delete-me
printf 'notes\nlocal edit\n' > notes.txt
