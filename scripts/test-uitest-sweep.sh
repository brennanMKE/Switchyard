#!/bin/zsh
# test-uitest-sweep.sh — the #0424 stale-clone sweep, checked without a VM.
#
# Loads uitest_run_is_live and uitest_classify_clones out of
# run-ui-tests-vm.sh (the script itself is not run: its top level boots VMs),
# feeds uitest_classify_clones a fake `tart list`, and checks each verdict.
# Owner pids are real processes: one live stand-in whose command line names
# run-ui-tests-vm.sh, one live process that is NOT this script (a recycled
# pid), and one pid that has exited.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/run-ui-tests-vm.sh"
GOLDEN="switchyard-uitest-golden"
typeset -g UITEST_LEGACY_MAX_AGE_SECS=10800
eval "$(sed -n '/^uitest_run_is_live() {/,/^}/p; /^uitest_classify_clones() {/,/^}/p' "$SCRIPT")"
(( $+functions[uitest_run_is_live] && $+functions[uitest_classify_clones] )) \
  || { print -r -- "FAIL: could not load the sweep functions from $SCRIPT"; exit 1; }

# Stand-ins get no stdout/stderr, so nothing waiting on this script's output
# waits on them; the EXIT trap kills them and the stand-in's own sleep.
zsh -c 'sleep 120; :' run-ui-tests-vm.sh </dev/null >/dev/null 2>&1 & live=$!
sleep 120 </dev/null >/dev/null 2>&1 & recycled=$!
zsh -c 'exit 0' </dev/null >/dev/null 2>&1 & dead=$!; wait $dead || true
trap 'pkill -P $live 2>/dev/null; kill $live $recycled 2>/dev/null; true' EXIT
sleep 1   # let the stand-in's argv settle before ps reads it

now=$(date -j -f '%Y%m%d%H%M%S' 20260928120000 +%s)
listing="Source Name                                    Disk Size Accessed     State
local  switchyard-uitest-golden                       140  73   4 days ago   stopped
local  switchyard-uitest-20260928-115900-$live-0382     140  73   1 minute ago running
local  switchyard-uitest-20260928-115900-$recycled-0 140  73   1 minute ago running
local  switchyard-uitest-20260928-115900-$dead-0383     140  73   1 minute ago running
local  switchyard-uitest-20260928-070000-406652       140  73   5 hours ago  running
local  switchyard-uitest-20260928-115000-406652       140  73   10 minutes ago running
local  switchyard-uitest-p0434-030012                 140  73   1 day ago    stopped
local  batty-uitest-20260928-115900-$dead-0           140  73   1 minute ago running
local  curator-uitest-golden                          140  73   4 days ago   stopped"

got="$(print -r -- "$listing" | uitest_classify_clones "$now")"
expected="keep switchyard-uitest-golden golden
keep switchyard-uitest-20260928-115900-$live-0382 owner-pid-$live-alive
sweep switchyard-uitest-20260928-115900-$recycled-0 owner-pid-$recycled-dead
sweep switchyard-uitest-20260928-115900-$dead-0383 owner-pid-$dead-dead
sweep switchyard-uitest-20260928-070000-406652 legacy-name-older-than-10800s
keep switchyard-uitest-20260928-115000-406652 legacy-name-too-young-to-judge
keep switchyard-uitest-p0434-030012 not-a-run-clone"

# The name start_guest actually builds must decode back to its run's pid.
index=0382
clone_line="$(grep -E '^[[:space:]]*CLONE="switchyard-uitest-' "$SCRIPT")"
eval "${clone_line## #}"
decoded="$(print -r -- "local  $CLONE  140 73 now running" | uitest_classify_clones "$now")"
[[ "$decoded" == *" owner-pid-$$-"* ]] \
  || { print -r -- "SWEEP TEST FAILED: start_guest's name '$CLONE' does not decode to pid $$ ($decoded)"; exit 1; }

if [[ "$got" == "$expected" ]]; then
  print -r -- "SWEEP TEST PASSED (7 verdicts + start_guest's name decodes; batty/curator VMs never considered)"
else
  print -r -- "SWEEP TEST FAILED"
  diff <(print -r -- "$expected") <(print -r -- "$got") || true
  exit 1
fi
