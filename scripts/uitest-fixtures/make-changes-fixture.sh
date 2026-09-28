#!/bin/zsh
# make-changes-fixture.sh <path> — the Changes-view UI fixture (#0442).
#
# Run inside the Tart guest by scripts/run-ui-tests-vm.sh; never shared,
# never host-live. One commit, then a working tree with every row kind the
# Changes view lists (guide §11 decision 30):
#
#   tracked.txt  20 lines committed; line 2 and line 18 edited, unstaged —
#                two hunks, far enough apart that git keeps them separate
#   staged.txt   modified and staged
#   gone.txt     deleted, unstaged
#   new.txt      untracked
#
# `git status --porcelain=v2` afterwards (measured, git 2.54.0):
#   1 .D … gone.txt / 1 M. … staged.txt / 1 .M … tracked.txt / ? new.txt
set -euo pipefail
repo="$1"
git init -q --initial-branch=changes-main "$repo"
cd "$repo"
git config user.email uitest@example.invalid
git config user.name 'Switchyard UI Test'
git config commit.gpgsign false
for i in {1..20}; do printf 'line %02d\n' $i; done > tracked.txt
printf 'staged before\n' > staged.txt
printf 'gone\n' > gone.txt
git add tracked.txt staged.txt gone.txt
git commit -q -m 'changes base commit'
sed -i '' -e 's/^line 02$/line 02 edited/' -e 's/^line 18$/line 18 edited/' tracked.txt
printf 'staged after\n' > staged.txt
git add staged.txt
rm gone.txt
printf 'new\n' > new.txt
