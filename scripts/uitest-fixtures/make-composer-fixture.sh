#!/bin/zsh
# make-composer-fixture.sh <path> — the commit composer UI fixture (#0568).
#
# Run inside the Tart guest by scripts/run-ui-tests-vm.sh; never shared,
# never host-live. Three commits and one staged file (guide §11 decision 45):
#
#   composer base commit     by the UI-test user
#   composer commit by Ann   by Ann Lee <ann@example.com>
#   composer paired commit   by the UI-test user, crediting
#                            Co-authored-by: Bob Quinn <bob@example.com>
#   staged.txt               new and staged
#
# commit.template names <path>-template.txt, beside the repository so it is
# not an untracked file in it. Its comment line must not reach the editor.
set -euo pipefail
repo="$1"
template="$repo-template.txt"
git init -q --initial-branch=composer-main "$repo"
cd "$repo"
git config user.email uitest@example.invalid
git config user.name 'Switchyard UI Test'
git config commit.gpgsign false
printf 'Composer template subject\n\n# A comment the editor must not show\nRefs:\n' > "$template"
git config commit.template "$template"
printf 'base\n' > base.txt
git add base.txt
git commit -q -m 'composer base commit'
printf 'ann\n' > ann.txt
git add ann.txt
git -c user.name='Ann Lee' -c user.email=ann@example.com commit -q -m 'composer commit by Ann'
git commit -q --allow-empty -m 'composer paired commit' -m 'Co-authored-by: Bob Quinn <bob@example.com>'
printf 'staged\n' > staged.txt
git add staged.txt
