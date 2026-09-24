#!/bin/zsh
# make-map-fixture.sh <path> — the branch-map UI fixture (#0410).
#
# Run inside the Tart guest by scripts/run-ui-tests-vm.sh; never shared,
# never host-live. Every commit gets its own fixed date so `--topo-order`
# (and so the map's recency order) is identical on every run.
#
# Shape (lane order the map must produce, left to right):
#   map-main      HEAD: "map base 01".."24", then "map main 01".."12", where
#                 "map main 09" is a --no-ff merge of a deleted two-commit
#                 topic (an unlabelled run). 36 rows: taller than the pane.
#   lane-01..24   one commit each ("lane-NN commit") off "map main 10",
#                 newest first -- 24 lanes, so the map is wider than the pane
#   feature-near  "near commit 1", "near commit 2" off "map main 11"
#   feature-mid   "mid commit 1".."3" off "map main 07";
#                 origin/feature-mid one commit behind it (a stub lane)
#   feature-deep  "deep commit 1".."3", "deep tip commit" off "map main 03"
#                 -- the oldest branch commit, so right of every lane above
#   merged-old    at "map base 04", 30 rows down map-main (a stub lane, last)
set -euo pipefail
repo="$1"
rm -rf "$repo"
git init -q --initial-branch=map-main "$repo"
cd "$repo"
git config user.email uitest@example.invalid
git config user.name 'Switchyard UI Test'
n=0
commit() {
  n=$((n + 1))
  local stamp="$((1700000000 + n * 60)) +0000"
  print -r -- "$1" > "file-$n.txt"
  git add "file-$n.txt"
  GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" git commit -q -m "$1"
}
for i in {01..24}; do
  commit "map base $i"
  [[ "$i" == 04 ]] && git branch merged-old
done
for i in 01 02 03; do commit "map main $i"; done
git branch feature-deep-base
for i in 04 05; do commit "map main $i"; done
for i in 06 07; do commit "map main $i"; done
git branch feature-mid-base
# A topic merged with --no-ff and deleted: history no ref names.
git switch -q -c topic-gone
commit "gone topic one"
commit "gone topic two"
git switch -q map-main
commit "map main 08"
n=$((n + 1)); stamp="$((1700000000 + n * 60)) +0000"
GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" git merge -q --no-ff -m "map main 09 merge gone topic" topic-gone
git branch -q -D topic-gone
for i in 10; do commit "map main $i"; done
git branch lane-base
commit "map main 11"
git branch feature-near-base
commit "map main 12"
# Oldest branch tips first, so recency puts them rightmost.
git switch -q -c feature-deep feature-deep-base
for i in 1 2 3; do commit "deep commit $i"; done
commit "deep tip commit"
git switch -q -c feature-mid feature-mid-base
for i in 1 2 3; do commit "mid commit $i"; done
git update-ref refs/remotes/origin/feature-mid feature-mid~1
git switch -q -c feature-near feature-near-base
for i in 1 2; do commit "near commit $i"; done
for i in {24..1}; do
  name=$(printf 'lane-%02d' "$i")
  git switch -q -c "$name" lane-base
  commit "$name commit"
done
git switch -q map-main
git branch -q -D feature-deep-base feature-mid-base feature-near-base lane-base
