#!/bin/zsh
# make-large-history-fixture.sh <path> — the large-history UI fixture
# (#0555, guide §11 decision 44).
#
# Run inside the Tart guest by scripts/run-ui-tests-vm.sh; never shared,
# never host-live. Written with one `git fast-import` stream so 6,002
# commits and 1,000 tags take about a second.
#
#   large-main   HEAD: "large commit 0001".."6000", a minute apart, the
#                newest now -- every tip is inside #0429's two-week filter.
#                Commits 0125, 0375, ... (every 250th from 125) end " needle":
#                24 of them, 20 inside History's newest 5,000 (1125..5875).
#   large-topic  "topic commit 1", "topic commit 2" off "large commit 5990"
#   rel-NNNN     a lightweight tag on every 6th commit (rel-0006..rel-6000)
set -euo pipefail
repo="$1"
git init -q --initial-branch=large-main "$repo"
cd "$repo"
git config user.email uitest@example.invalid
git config user.name 'Switchyard UI Test'
git config commit.gpgsign false
now=$(date +%s)
{
  for n in {1..6000}; do
    num=$(printf '%04d' $n)
    subject="large commit $num"
    (( n % 250 == 125 )) && subject="$subject needle"
    when=$(( now - (6000 - n) * 60 ))
    print "commit refs/heads/large-main"
    print "mark :$n"
    print "author Switchyard UI Test <uitest@example.invalid> $when +0000"
    print "committer Switchyard UI Test <uitest@example.invalid> $when +0000"
    print "data ${#subject}"
    print -r -- "$subject"
    (( n > 1 )) && print "from :$(( n - 1 ))"
    print "M 644 inline large.txt"
    print "data ${#num}"
    print -r -- "$num"
    print ""
  done
  for t in 1 2; do
    subject="topic commit $t"
    when=$(( now - 30 + t ))
    print "commit refs/heads/large-topic"
    print "mark :$(( 6000 + t ))"
    print "author Switchyard UI Test <uitest@example.invalid> $when +0000"
    print "committer Switchyard UI Test <uitest@example.invalid> $when +0000"
    print "data ${#subject}"
    print -r -- "$subject"
    (( t == 1 )) && print "from :5990" || print "from :6001"
    print "M 644 inline topic.txt"
    print "data 1"
    print "$t"
    print ""
  done
  for n in {6..6000..6}; do
    print "reset refs/tags/rel-$(printf '%04d' $n)"
    print "from :$n"
    print ""
  done
} | git fast-import --quiet
git checkout -q -f large-main
