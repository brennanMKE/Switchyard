#!/bin/zsh
# make-stash-fixture.sh <path> — the stash UI fixture (#0496).
#
# Run inside the Tart guest by scripts/run-ui-tests-vm.sh; never shared,
# never host-live. One commit, then two stashes, and a clean working tree
# (guide §11 decision 36):
#
#   stash@{1}  "older stash"  notes.txt: a second line added
#   stash@{0}  "newer stash"  notes.txt: a different second line, and the
#                             untracked todo.txt (stashed with -u)
#
# The two edits differ in length: a same-size rewrite inside one second is
# racily clean to git, and `stash push` then saves nothing (measured).
#
# `git stash list` afterwards (measured, git 2.54.0):
#   stash@{0}: On stash-main: newer stash
#   stash@{1}: On stash-main: older stash
set -euo pipefail
repo="$1"
git init -q --initial-branch=stash-main "$repo"
cd "$repo"
git config user.email uitest@example.invalid
git config user.name 'Switchyard UI Test'
git config commit.gpgsign false
printf 'first line\n' > notes.txt
git add notes.txt
git commit -q -m 'stash base commit'
printf 'first line\nolder change\n' > notes.txt
git stash push -q -m 'older stash'
printf 'first line\nnewer change here\n' > notes.txt
printf 'todo\n' > todo.txt
git stash push -q -u -m 'newer stash'
