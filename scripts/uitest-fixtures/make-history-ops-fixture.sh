#!/bin/zsh
# make-history-ops-fixture.sh <dir> — the history-operation VM suite's
# fixture (umbrella #0590).
#
# Run inside the Tart guest by scripts/run-ui-tests-vm.sh; never shared,
# never host-live, never the network. Built once as <dir>/base, then copied
# (`cp -R`, so every copy has the same oids) into one repository per spike
# class, each with the branch that spike needs checked out:
#
#   <dir>/merge-ff  <dir>/merge-true  <dir>/merge-conflict  <dir>/cherry-pick
#   <dir>/revert    <dir>/set-tip     <dir>/refs                 -> on main
#   <dir>/rebase                                                 -> on rebase-topic
#   <dir>/rebase-conflict                                        -> on clash-topic
#   <dir>/squash  <dir>/fixup  <dir>/swap  <dir>/delete
#   <dir>/edit-message  <dir>/split                              -> on stack
#   <dir>/fixup-newer                                            -> on wip
#
# Every commit is dated three days ago plus a minute per commit, so the
# topological order (and the branch map's lane order) is identical on every
# run and every tip is inside the map's default two-week recency filter.
# The oids differ per run (the dates are relative); the spikes read them
# with git, never hard-code them. One author, "Switchyard UI Test".
#
# Shape — every commit adds its own file unless noted, so only the two
# "clash" pairs can conflict:
#
#   main            "hist root" (README.md)
#                   "hist shared" (shared.txt = alpha/beta/gamma)   <- tag v1.0
#                   "hist main three" (main3.txt)                   <- revert target
#                   "hist main tip" (main4.txt, and shared.txt's beta line
#                                    becomes "beta from main")      <- HEAD of main
#   ff-topic        off "hist main tip": "ff topic commit" (ff.txt) — merging it
#                   could fast-forward; the app always merges --no-ff
#   diverged-topic  off "hist main three": "diverged topic one" (diverged1.txt),
#                   "diverged topic two" (diverged2.txt) — a true merge
#   clash-topic     off "hist main three": "clash topic commit", beta line ->
#                   "beta from clash" — conflicts with "hist main tip" in a
#                   merge into main AND when rebased onto main
#   pick-source     off "hist main three": "pick source commit" (pick.txt)
#   rebase-topic    off "hist shared": "rebase topic one" (rebase1.txt),
#                   "rebase topic two" (rebase2.txt) — rebases cleanly onto main
#   stack           off "hist main tip": "stack one" (s1.txt), "stack two"
#                   (s2.txt), "stack split" (split-a.txt AND split-b.txt: two
#                   hunks, so Split has a choice), "stack tip" (s4.txt).
#                   Four commits on purpose: the branch map folds a run of
#                   three or more quiet commits into one "Folded N commits"
#                   row (#0427), and a folded commit has no History row to
#                   select — measured, the first VM run's five-commit stack
#                   folded "stack four".."stack two" and every stack spike
#                   failed at "No History row".
#   wip             ONLY in <dir>/fixup-newer (#0603), so no other copy's
#                   map gains a lane: off "hist main tip", "wip good" with a
#                   body (wip.txt = "first draft"), then three commits whose
#                   whole message is "wip" — Brennan's workflow (guide §11
#                   decision 48). Each wip rewrites wip.txt and adds its own
#                   wipN.txt.
set -euo pipefail
dir="$1"
rm -rf "$dir"
mkdir -p "$dir"
export GIT_CONFIG_NOSYSTEM=1
base=$(( $(date +%s) - 3 * 86400 ))
n=0
git init -q --initial-branch=main "$dir/base"
cd "$dir/base"
git config user.email uitest@example.invalid
git config user.name 'Switchyard UI Test'
git config commit.gpgsign false

# commit <subject> <file> <content> — write <file>, stage it, commit with
# the next minute's date.
commit() {
  n=$((n + 1))
  local stamp="$((base + n * 60)) +0000"
  print -r -- "$3" > "$2"
  git add "$2"
  GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" git commit -q -m "$1"
}

commit "hist root" README.md "history operations fixture"
commit "hist shared" shared.txt $'alpha\nbeta\ngamma'
git tag v1.0
commit "hist main three" main3.txt "main three"
git branch diverged-topic
git branch clash-topic
git branch pick-source
git branch rebase-topic HEAD~1
print -r -- $'alpha\nbeta from main\ngamma' > shared.txt
git add shared.txt
commit "hist main tip" main4.txt "main four"
git branch ff-topic
git branch stack

git switch -q ff-topic
commit "ff topic commit" ff.txt "fast-forwardable"
git switch -q diverged-topic
commit "diverged topic one" diverged1.txt "diverged one"
commit "diverged topic two" diverged2.txt "diverged two"
git switch -q clash-topic
commit "clash topic commit" shared.txt $'alpha\nbeta from clash\ngamma'
git switch -q pick-source
commit "pick source commit" pick.txt "picked"
git switch -q rebase-topic
commit "rebase topic one" rebase1.txt "rebase one"
commit "rebase topic two" rebase2.txt "rebase two"
git switch -q stack
commit "stack one" s1.txt "one"
commit "stack two" s2.txt "two"
n=$((n + 1)); stamp="$((base + n * 60)) +0000"
print -r -- "split a" > split-a.txt
print -r -- "split b" > split-b.txt
git add split-a.txt split-b.txt
GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" git commit -q -m "stack split"
commit "stack tip" s4.txt "tip"
git switch -q main

cd "$dir"
for spec in merge-ff:main merge-true:main merge-conflict:main cherry-pick:main \
            revert:main set-tip:main refs:main \
            rebase:rebase-topic rebase-conflict:clash-topic \
            squash:stack fixup:stack swap:stack delete:stack edit-message:stack split:stack; do
  name="${spec%%:*}"
  branch="${spec#*:}"
  cp -R base "$name"
  git -C "$name" switch -q "$branch"
done

# #0603: the wip stack, in its own copy only.
cp -R base fixup-newer
cd "$dir/fixup-newer"
git switch -q -c wip main
n=$((n + 1)); stamp="$((base + n * 60)) +0000"
print -r -- "first draft" > wip.txt
git add wip.txt
GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" \
  git commit -q -m "wip good" -m "The message Brennan wrote first; the wips fold into it."
for step in 1 2 3; do
  n=$((n + 1)); stamp="$((base + n * 60)) +0000"
  print -r -- "draft $step" > wip.txt
  print -r -- "wip $step" > "wip$step.txt"
  git add wip.txt "wip$step.txt"
  GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" git commit -q -m "wip"
done
