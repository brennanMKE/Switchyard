#!/bin/zsh
# make-diffopts-fixture.sh <path> — the diff options UI fixture (guide §11
# decision 42).
#
# Run inside the Tart guest by scripts/run-ui-tests-vm.sh; never shared,
# never host-live.
#
#   "diffopts base commit"        code.txt (30 lines), notes.txt, spaces.txt
#   "diffopts whitespace commit"  notes.txt: alpha -> alpha edited;
#                                 spaces.txt: trailing spaces only
#   working tree (unstaged)       code.txt: foo(); wrapped in `if ready {`,
#                                 compute(1) -> compute(10);
#                                 spaces.txt: a trailing tab only
set -euo pipefail
repo="$1"
git init -q --initial-branch=diffopts-main "$repo"
cd "$repo"
git config user.email uitest@example.invalid
git config user.name 'Switchyard UI Test'
git config commit.gpgsign false
code() {
  for i in {1..10}; do printf 'line %02d\n' $i; done
  printf '%s\n' "$@"
  for i in {16..30}; do printf 'line %02d\n' $i; done
}
code 'setup();' 'foo();' 'bar();' 'baz();' 'total = compute(1);' > code.txt
printf 'alpha\n' > notes.txt
printf 'keep\n' > spaces.txt
git add code.txt notes.txt spaces.txt
git commit -q -m 'diffopts base commit'
printf 'alpha edited\n' > notes.txt
printf 'keep  \n' > spaces.txt
git commit -q -am 'diffopts whitespace commit'
code 'setup();' 'if ready {' '    foo();' '}' 'bar();' 'baz();' 'total = compute(10);' > code.txt
printf 'keep\t\n' > spaces.txt
