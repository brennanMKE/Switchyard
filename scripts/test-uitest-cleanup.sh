#!/bin/zsh
# test-uitest-cleanup.sh — #0460: once run-ui-tests-vm.sh has cloned a VM,
# every way the run can end stops and deletes that clone. No VM: a fake
# `tart` (and fake `vm_stat`/`df`, so the host's memory and disk never
# decide the outcome) sits first on PATH and logs every call; the real
# script runs under `zsh -f` so ~/.zshenv cannot put the real tart back.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/scripts/run-ui-tests-vm.sh"
WORK="$REPO/build/test-uitest-cleanup-$$"
mkdir -p "$WORK/bin"
# A clone the script failed to stop leaves its fake `tart run` looping (60 s
# at most); kill those too, so the test leaves nothing running.
trap 'pkill -f "$WORK/bin/tart run" 2>/dev/null; rm -rf "$WORK"; true' EXIT

cat > "$WORK/bin/tart" <<'FAKE'
#!/bin/zsh -f
print -r -- "tart $*" >> "$FAKE_TART_LOG"
case "$1" in
  list) print "Source Name Disk Size Accessed State"
        print "local switchyard-uitest-golden 140 73 now stopped" ;;
  run)  # Stays up, bounded, until `tart stop` marks this clone stopped.
        for i in {1..120}; do [[ -f "$FAKE_TART_DIR/stopped-$2" ]] && exit 0; sleep 0.5; done ;;
  stop) touch "$FAKE_TART_DIR/stopped-$2" ;;
  exec)
    case "$FAKE_TART_MODE:$*" in
      fixture-fails:*make-map-fixture*) exit 1 ;;
      fixture-hangs:*make-map-fixture*) touch "$FAKE_TART_DIR/started"; sleep 3; exit 0 ;;
      branch-fails:*symbolic-ref*) exit 1 ;;
      tests-fail:*xcodebuild*) print "** TEST FAILED **"; exit 65 ;;
      *symbolic-ref*) print uitest-main ;;
      *"tar -C"*) tar -cf - -T /dev/null ;;
    esac ;;
esac
exit 0
FAKE
print -r -- '#!/bin/zsh -f
print "Pages free: 100000000."; print "Pages inactive: 0."; print "Pages purgeable: 0."' > "$WORK/bin/vm_stat"
print -r -- '#!/bin/zsh -f
print "Filesystem 1024-blocks Used Available"; print "/dev/disk1 999999999 1 104857600"' > "$WORK/bin/df"
chmod +x "$WORK/bin/tart" "$WORK/bin/vm_stat" "$WORK/bin/df"

failures=0
check() {   # check <case> <description> <condition, eval'd>
  if eval "$3"; then print -r -- "  ok   $1: $2"; else print -r -- "  FAIL $1: $2"; failures=$(( failures + 1 )); fi
}

# run_case <mode> <spike-filter> [term] — runs the script, sets RC, LOG, OUT, CLONE.
run_case() {
  local mode="$1" filter="$2" term="${3:-}"
  local dir="$WORK/$mode"; mkdir -p "$dir"
  LOG="$dir/tart.log"; OUT="$dir/out"; : > "$LOG"
  FAKE_TART_MODE="$mode" FAKE_TART_LOG="$LOG" FAKE_TART_DIR="$dir" \
    PATH="$WORK/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    zsh -f "$SCRIPT" "$filter" > "$OUT" 2>&1 &
  local pid=$!
  if [[ -n "$term" ]]; then
    for i in {1..120}; do [[ -f "$dir/started" ]] && break; sleep 0.5; done
    kill -TERM "$pid" 2>/dev/null || true
  fi
  RC=0; wait "$pid" || RC=$?
  CLONE="$(awk '$2 == "clone" { print $4; exit }' "$LOG")"
}

# cleaned <case>: the clone was stopped and deleted exactly once.
cleaned() {
  check "$1" "a clone was created" '[[ -n "$CLONE" ]]'
  check "$1" "clone stopped exactly once" '[[ "$(grep -cx "tart stop $CLONE" "$LOG")" == 1 ]]'
  check "$1" "clone deleted exactly once" '[[ "$(grep -cx "tart delete $CLONE" "$LOG")" == 1 ]]'
}

print -r -- "case 1: a fixture script fails in the guest (errexit inside start_guest)"
run_case fixture-fails launch
check fixture-fails "script exits non-zero (rc=$RC)" '(( RC != 0 ))'
cleaned fixture-fails

print -r -- "case 2: a substitution fails in the guest (errexit inside \$(...) in start_guest)"
run_case branch-fails launch
check branch-fails "script exits non-zero (rc=$RC)" '(( RC != 0 ))'
cleaned branch-fails

print -r -- "case 3: the run is sent SIGTERM while a clone is up"
run_case fixture-hangs launch term
check fixture-hangs "script exits 143 (rc=$RC)" '(( RC == 143 ))'
cleaned fixture-hangs

print -r -- "case 4: xcodebuild fails inside run_spike's set +e window"
run_case tests-fail 0382
check tests-fail "script exits with xcodebuild's 65 (rc=$RC)" '(( RC == 65 ))'
check tests-fail "the run reached its RESULT summary" 'grep -qF "RESULT: TEST FAILED (exit 65)" "$OUT"'
cleaned tests-fail

if (( failures == 0 )); then
  print -r -- "CLEANUP TEST PASSED (4 cases: fixture failure, substitution failure, SIGTERM, tolerated test failure)"
else
  print -r -- "CLEANUP TEST FAILED ($failures checks)"
  exit 1
fi
