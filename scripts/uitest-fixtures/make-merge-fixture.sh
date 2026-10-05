#!/bin/zsh
# make-merge-fixture.sh <dir> — the Merge into Current Branch fixture (#0578).
#
# Run inside the Tart guest by scripts/run-ui-tests-vm.sh; never shared,
# never host-live. Brennan's 2026-10-05 report, in two shapes:
#
#   <dir>/ff        merge-main: "merge base commit" (README.md)
#                   docs2:      + "docs2 adds docs.md" (docs.md)
#                   — fast-forwardable; the app's --no-ff still merges
#   <dir>/diverged  as ff, plus merge-main: "main moves on" (main.txt)
#                   — a true merge
#
# Both are left on merge-main with a clean tree.
set -euo pipefail
root="$1"
for shape in ff diverged; do
  repo="$root/$shape"
  git init -q --initial-branch=merge-main "$repo"
  cd "$repo"
  git config user.email uitest@example.invalid
  git config user.name 'Switchyard UI Test'
  git config commit.gpgsign false
  printf 'readme\n' > README.md
  git add README.md && git commit -q -m 'merge base commit'
  git checkout -q -b docs2
  printf 'docs\n' > docs.md
  git add docs.md && git commit -q -m 'docs2 adds docs.md'
  git checkout -q merge-main
  if [[ $shape == diverged ]]; then
    printf 'main\n' > main.txt
    git add main.txt && git commit -q -m 'main moves on'
  fi
done
