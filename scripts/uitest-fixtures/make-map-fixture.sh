#!/bin/zsh
# make-map-fixture.sh <path> — the branch-map UI fixture (#0410).
#
# Run inside the Tart guest by scripts/run-ui-tests-vm.sh; never shared,
# never host-live. Every commit gets its own date -- three days ago plus a
# minute per commit -- so `--topo-order` (and so the map's lane order) is
# identical on every run, and every tip is inside #0429's default two-week
# recency filter except the two stale branches, which are 40 days old.
#
# Shape (the #0426 staircase tree the map must produce, left to right):
#   map-main      lane 0, HEAD and the root (no `main` here, so HEAD's
#                 branch roots the tree): "map base 01".."24", then
#                 "map main 01".."12", where "map main 09" is a --no-ff merge
#                 of a deleted two-commit topic -- history no branch claims,
#                 so the map does not draw it. 37 rows: taller than the pane.
#   feature-near  lane 1, the nearest fork: "near commit 1", "near commit 2"
#                 off "map main 11", which sits one row below "near commit 1"
#   lane-01..24   lanes 2-25: one commit each ("lane-NN commit") off
#                 "map main 10", newest first -- wider than the pane
#   feature-mid   lane 26: "mid commit 1".."3" off "map main 07";
#                 origin/feature-mid, one commit behind, folds into its lane
#   feature-deep  lane 27: "deep commit 1".."3", "deep tip commit" off
#                 "map main 03" -- the farthest fork with commits of its own
#   merged-old    lane 28, a stub at "map base 04", row 33 of map-main
#                 (#0429 at the default two-week filter: stale-base and
#                 fresh-child sit between feature-deep and merged-old as
#                 lanes 28-29, and merged-old moves to lane 30)
#   stale-base    "stale base commit", 40 days old, off "map base 04"; its
#                 child fresh-child ("fresh child commit") is recent, so the
#                 filter keeps stale-base as a greyed context lane
#   stale-only    "stale only commit", 40 days old, off "map base 04" with no
#                 child: the default filter hides it
# #0427 folds map-main's quiet runs: "map main 06".."04" (3),
# "map main 02".."map base 05" (22) and "map base 03".."01" (3), which
# puts "map base 04" on row 10 and the map at 12 rows.
set -euo pipefail
repo="$1"
base=$(( $(date +%s) - 3 * 86400 ))
old="$(( $(date +%s) - 40 * 86400 )) +0000"
rm -rf "$repo"
git init -q --initial-branch=map-main "$repo"
cd "$repo"
git config user.email uitest@example.invalid
git config user.name 'Switchyard UI Test'
n=0
commit() {
  n=$((n + 1))
  local stamp="$((base + n * 60)) +0000"
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
n=$((n + 1)); stamp="$((base + n * 60)) +0000"
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
# #0429: two branches older than the default filter, off "map base 04".
git switch -q -c stale-base merged-old
print -r -- "stale base" > stale-base.txt
git add stale-base.txt
GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" git commit -q -m "stale base commit"
git switch -q -c fresh-child
commit "fresh child commit"
git switch -q -c stale-only merged-old
print -r -- "stale only" > stale-only.txt
git add stale-only.txt
GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" git commit -q -m "stale only commit"
git switch -q map-main
git branch -q -D feature-deep-base feature-mid-base feature-near-base lane-base
