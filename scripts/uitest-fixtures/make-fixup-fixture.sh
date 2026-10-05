#!/bin/zsh
# make-fixup-fixture.sh <dir> — the Fixup with Parent UI fixture (#0582,
# guide §11 decision 46).
#
# Run inside the Tart guest by scripts/run-ui-tests-vm.sh; never shared,
# never host-live, no network. <dir> is a repository on `fixup-main`, oldest
# first. Every commit is dated three days ago plus a minute per commit, so
# every tip sits inside the branch map's two-week recency filter (measured:
# commits dated 2020-2023 are filtered out and no History row shows). Oids
# differ per run; the spike reads them with git.
#
#   fixup root     root.txt
#   fixup parent   parent.txt = "parent\n"; message "fixup parent\n\nparent
#                  body line\n"; authored by Parent Author
#   fixup middle   parent.txt += "folded by middle\n", adds middle.txt — the
#                  commit the spike folds into its parent (not the tip)
#   fixup tip      tip.txt
#
# plus staged.txt, new and STAGED, so the fold must leave staged work alone.
#
# TODO(#0590+): move onto Workstream C's history-ops fixture once it lands.
set -euo pipefail
dir="$1"
export GIT_CONFIG_NOSYSTEM=1
git init -q --initial-branch=fixup-main "$dir"
cd "$dir"
git config user.email uitest@example.invalid
git config user.name 'Switchyard UI Test'
git config commit.gpgsign false

base=$(( $(date +%s) - 3 * 86400 ))
n=0
commit() { # <message arguments...>
  n=$(( n + 1 ))
  local stamp="@$(( base + n * 60 )) +0000"
  GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" git commit -q "$@"
}

printf 'root\n' > root.txt
git add root.txt
commit -m 'fixup root'

printf 'parent\n' > parent.txt
git add parent.txt
GIT_AUTHOR_NAME='Parent Author' GIT_AUTHOR_EMAIL=parent@example.invalid \
  commit -m 'fixup parent' -m 'parent body line'

printf 'parent\nfolded by middle\n' > parent.txt
printf 'middle\n' > middle.txt
git add parent.txt middle.txt
commit -m 'fixup middle' -m 'middle body line'

printf 'tip\n' > tip.txt
git add tip.txt
commit -m 'fixup tip'

printf 'staged\n' > staged.txt
git add staged.txt
