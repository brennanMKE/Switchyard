#!/bin/zsh
# make-blame-fixture.sh <path> — the file history and blame UI fixture
# (guide §11 decision 39).
#
# Run inside the Tart guest by scripts/run-ui-tests-vm.sh; never shared,
# never host-live. One file, renamed once, and edited in the working tree:
#
#   "blame first commit"   notes-old.txt: alpha, bravo, charlie
#   "blame rename commit"  notes-old.txt -> notes.txt
#   "blame edit commit"    notes.txt: bravo -> BRAVO edited
#   "blame other commit"   other.txt only — not in notes.txt's history
#   working tree           notes.txt: "delta local" appended
set -euo pipefail
repo="$1"
git init -q --initial-branch=blame-main "$repo"
cd "$repo"
git config user.email uitest@example.invalid
git config user.name 'Switchyard UI Test'
git config commit.gpgsign false
printf 'alpha\nbravo\ncharlie\n' > notes-old.txt
git add notes-old.txt
git commit -q -m 'blame first commit'
git mv notes-old.txt notes.txt
git commit -q -m 'blame rename commit'
printf 'alpha\nBRAVO edited\ncharlie\n' > notes.txt
git commit -q -am 'blame edit commit'
printf 'other\n' > other.txt
git add other.txt
git commit -q -m 'blame other commit'
printf 'alpha\nBRAVO edited\ncharlie\ndelta local\n' > notes.txt
