#!/bin/zsh
# run-ui-tests-vm.sh — run Switchyard's UI tests inside a disposable Tart VM.
#
# UI tests never run on cameron's host (docs/ui-test-automation-vm.md,
# AGENTS.md Rule 13); they run in a per-run APFS clone of
# `switchyard-uitest-golden` that is deleted afterwards. The golden image is
# only ever cloned, never run.
#
# Per run:
#   1. Preflight: Tart present, golden image present, disk free, memory
#      requested through the generic memory-signal protocol when the host is
#      short (the machine's observer frees what it can), stale
#      `switchyard-uitest-*` clones swept.
#   2. Export a clean snapshot: `git archive HEAD` — never the live working
#      copy. EXCEPTION, visible and loud: when build/uitest-overlay/ exists
#      and is non-empty its tree is copied over the export — that is how a
#      round exercises its own uncommitted work (the reviewer commits after
#      the round). Post-commit runs leave it empty and the export is pure
#      HEAD.
#   3. Clone, boot headless with the export mounted read-only.
#   4. In the guest: copy the source in, generate the fixture repository
#      (`git init` + a commit — nothing shared read-write, nothing host-live
#      touched), then run
#      `xcodebuild -scheme 'Switchyard UITests' test` (XCUITest) unsigned
#      (`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`, and
#      `ENABLE_APP_SANDBOX=NO` so the app can read the guest fixture), teeing
#      the log, with the result bundle captured.
#   5. Stream the results back to `build/ui-tests/<run-id>/`.
#   6. Cleanup on EXIT (trap): stop and delete the clone, remove the export.
#
# The export share is read-only on purpose; results come back via `tart exec
# … tar`, not through the share. Run this script in the foreground of a
# shell: a dropped session costs a clone, not a work session.

set -euo pipefail

GOLDEN="switchyard-uitest-golden"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
GUEST_USER="admin"
GUEST_SRC="/Users/$GUEST_USER/src"
GUEST_RESULTS="/Users/$GUEST_USER/results"
GUEST_FIXTURE="/Users/$GUEST_USER/uitest-fixture-repo"
GUEST_FIXTURE_BRANCH="uitest-main"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
# Optional spike filter: pass an issue number (e.g. `0383`) to run just that
# spike's clone; with no argument all four run, each in its own clone.
SPIKE_FILTER="${1:-}"
CLONE=""
# Scratch lives under the worktree's build/ (gitignored), never /tmp.
EXPORT="$REPO/build/ui-tests-export/$RUN_ID"
RESULTS_DIR="$REPO/build/ui-tests/$RUN_ID"
OVERLAY_DIR="$REPO/build/uitest-overlay"
BOOT_TIMEOUT_SECS=120

log()  { print -r -- "==> $*"; }
fail() { print -r -- "!! $*" >&2; exit 1; }

cleanup() {
  local rc=$?
  trap - EXIT
  log "Cleaning up (exit $rc)"
  # memory-signal release: tell the observer this run is done with any
  # memory it freed. Best effort — never affects the exit code.
  if [[ -n "${MEMORY_REQUEST_ID:-}" ]]; then
    /usr/bin/python3 - "${MEMORY_COORD_DIR:-}" "$MEMORY_REQUEST_ID" <<'PY' 2>/dev/null || true
import json, os, sys, datetime
dir, rid = sys.argv[1:3]
if not dir:
    raise SystemExit(0)
os.makedirs(os.path.join(dir, "release"), exist_ok=True)
doc = {"id": rid, "released": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
with open(os.path.join(dir, "release", rid + ".json"), "w") as f:
    json.dump(doc, f, indent=2)
PY
  fi
  tart stop "$CLONE" >/dev/null 2>&1 || true
  tart delete "$CLONE" >/dev/null 2>&1 || true
  rm -rf "$EXPORT"
}
trap cleanup EXIT

# --- Preflight -------------------------------------------------------------

command -v tart >/dev/null || fail "Tart is not installed (brew install cirruslabs/cli/tart)"
tart list | grep -q "$GOLDEN" || fail "Golden image '$GOLDEN' not found"

free_kb=$(df -k / | awk 'NR == 2 { print $4 }')
(( free_kb / 1024 / 1024 >= 20 )) || fail "Only $((free_kb / 1024 / 1024)) GiB free on / — need at least 20 GiB"

# --- Memory (generic memory-signal protocol) -------------------------------
# The guest needs its RAM plus host build headroom. This script states the
# need through the memory-signal protocol and waits for this machine's
# observer to free memory; what the observer does (unload cached AI models,
# drop caches, ask the user) is configured on the machine, never here.
# See PROTOCOL.md in the protocol's home for the wire format.

# Keep in sync with the golden image's memory (`tart set --memory`).
typeset -g GUEST_MEM_MB=12288

memory_available_bytes() {
  local page free inactive purgeable
  page=$(sysctl -n vm.pagesize)
  free=$(vm_stat | awk '/Pages free/ {gsub("\\.","",$3); print $3}')
  inactive=$(vm_stat | awk '/Pages inactive/ {gsub("\\.","",$3); print $3}')
  purgeable=$(vm_stat | awk '/Pages purgeable/ {gsub("\\.","",$3); print $3}')
  print -r -- $(( (free + inactive + purgeable) * page ))
}

# 0 = a live observer owns the spool (heartbeat fresh), 1 = none.
memory_observer_live() {
  local dir hb now mtime
  dir="${MEMORY_COORDINATION_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/memory-coordination}"
  hb="$dir/heartbeat"
  [[ -f "$hb" ]] || return 1
  now=$(date +%s)
  mtime=$(stat -f %m "$hb" 2>/dev/null) || return 1
  (( now - mtime <= 15 ))
}

# Emits a request and polls for ready/failed. 0 ready, 3 failed, 4 timeout
# or no observer. Sets MEMORY_REQUEST_ID for the release in cleanup.
memory_request_and_wait() {
  local need_bytes=$1 reason=$2 timeout=${3:-120}
  local dir id req deadline
  dir="${MEMORY_COORDINATION_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/memory-coordination}"
  id="run-ui-tests-vm-$$-$(date +%s)"
  req="$dir/requests/$id.json"
  MEMORY_REQUEST_ID="$id"
  MEMORY_COORD_DIR="$dir"

  memory_observer_live || { MEMORY_REQUEST_ID=""; return 4; }

  mkdir -p "$dir/requests" "$dir/ready" "$dir/failed" "$dir/release"
  /usr/bin/python3 - "$req" "$id" "$need_bytes" "$reason" "$$" <<'PY'
import json, os, sys, datetime
path, rid, need, reason, pid = sys.argv[1:6]
doc = {
    "id": rid,
    "resource": "memory",
    "bytes": int(need),
    "requester": "run-ui-tests-vm",
    "reason": reason,
    "pid": int(pid),
    "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(path, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

  deadline=$(( SECONDS + timeout ))
  while (( SECONDS < deadline )); do
    [[ -f "$dir/ready/$id.json" ]] && return 0
    if [[ -f "$dir/failed/$id.json" ]]; then
      /usr/bin/python3 -c 'import json,sys; print("memory-signal failed:", json.load(open(sys.argv[1])).get("reason","?"))' "$dir/failed/$id.json" >&2
      return 3
    fi
    sleep 2
  done
  return 4
}

need_bytes=$(( (GUEST_MEM_MB + 4096) * 1024 * 1024 ))
avail_bytes=$(memory_available_bytes)
if (( avail_bytes < need_bytes )); then
  log "Host memory short ($(( avail_bytes / 1073741824 )) GiB of $(( need_bytes / 1073741824 )) GiB) — requesting via the memory-signal protocol"
  set +e
  memory_request_and_wait "$need_bytes" "Tart VM UI-test run needs guest RAM plus build headroom" 120
  mem_rc=$?
  set -e
  (( mem_rc == 0 )) || fail "Memory request not fulfilled (rc=$mem_rc). Free memory, or set up a memory-signal observer (MEMORY_COORDINATION_DIR=${MEMORY_COORDINATION_DIR:-$HOME/.local/state/memory-coordination})"
  avail_bytes=$(memory_available_bytes)
  (( avail_bytes >= need_bytes )) || fail "Observer signaled ready but memory is still short ($(( avail_bytes / 1073741824 )) GiB of $(( need_bytes / 1073741824 )) GiB)"
fi

# A SIGKILL (e.g. the OOM above) skips this script's trap, so sweep any
# clones left behind by earlier runs. Only names shaped
# `switchyard-uitest-<YYYYMMDD>-<HHMMSS>-<pid>` — this script's own run-id
# shape — are swept, which structurally excludes the golden image; the
# explicit golden check inside the loop is belt and braces after the
# 2026-09-13 incident where a plain name-prefix match deleted the golden.
stale=$(tart list | awk '$2 ~ /^switchyard-uitest-[0-9]{8}-[0-9]{6}-[0-9]+$/ { print $2 }' | grep -v -- "${CLONE:-__none__}" || true)
foreign=$(tart list | awk '$2 ~ /^switchyard-uitest-/ && $2 !~ /^switchyard-uitest-[0-9]{8}-[0-9]{6}-[0-9]+$/ && $2 != "switchyard-uitest-golden" { print $2 }' || true)
for old in ${=stale}; do
  if [[ "$old" == "$GOLDEN" ]]; then
    print -r -- "!! refusing to sweep the golden image — this is a script bug" >&2
    continue
  fi
  log "Sweeping stale clone: $old"
  tart stop "$old" >/dev/null 2>&1 || true
  tart delete "$old" >/dev/null 2>&1 || true
done
for other in ${=foreign}; do
  log "Leaving non-run clone alone: $other"
done

# --- Export a clean snapshot ----------------------------------------------

mkdir -p "$EXPORT/src"
log "Exporting HEAD to $EXPORT/src"
git -C "$REPO" archive HEAD | tar -x -C "$EXPORT/src"

# Round escape hatch: a round's work is uncommitted until its reviewer
# commits, so the round stages exactly the files it changed/added into
# build/uitest-overlay/ (as a repo-root-shaped tree) and this run builds
# HEAD plus that overlay. Post-commit runs leave it empty and get the pure
# `git archive HEAD` export. Loud so a stale overlay can never pass
# unnoticed.
if [[ -d "$REPO/build/uitest-overlay" ]] && [[ -n "$(ls -A "$REPO/build/uitest-overlay" 2>/dev/null)" ]]; then
  log "WARNING: overlaying build/uitest-overlay over the archived export (uncommitted round work)"
  rsync -a "$REPO/build/uitest-overlay/" "$EXPORT/src/"
fi

# --- Per-spike clones and runs ---------------------------------------------
#
# Measured round 2, #0395, in the guest (five suite runs plus a four-launch
# manual probe with a CGWindowList probe): the app under XCUITest opens its
# window on a session's FIRST TWO launches and on NO later one; a session
# whose first launch failed never opens one again; direct launches of the
# same binary never miss — an automation-launch property, not an app defect.
# The shape that worked every time is a VIRGIN clone whose first launch is
# the smoke test and whose second is the spike re-derivation. So each spike
# gets its own fresh clone, with the smoke test riding along as launch #1.

typeset -g TEST_RC=0
typeset -g CLONE=""

run_spike() {
  local index="$1" label="$2"; shift 2
  local tests="" t
  for t in "$@"; do tests="$tests -only-testing:'SwitchyardUITests/$t'"; done
  # Run-id-shaped name: the stale sweep matches only
  # `switchyard-uitest-<YYYYMMDD>-<HHMMSS>-<numeric>`, so the suffix stays
  # purely numeric and every crashed run's clone is sweepable.
  CLONE="switchyard-uitest-$(date +%Y%m%d-%H%M%S)-$(( $$ * 10 + index ))"
  log "[$label] Cloning $GOLDEN → $CLONE"
  tart clone "$GOLDEN" "$CLONE"
  log "[$label] Booting $CLONE (headless, export mounted read-only)"
  tart run "$CLONE" --no-graphics --dir=run:"$EXPORT":ro >"$EXPORT/tart-run-$label.log" 2>&1 &
  local boot_deadline=$(( SECONDS + BOOT_TIMEOUT_SECS ))
  until tart exec "$CLONE" true >/dev/null 2>&1; do
    (( SECONDS < boot_deadline )) || fail "[$label] guest not reachable within ${BOOT_TIMEOUT_SECS}s (see $EXPORT/tart-run-$label.log — kept until cleanup)"
    sleep 5
  done
  log "[$label] Guest reachable; copying source, generating the fixture"
  tart exec "$CLONE" /bin/zsh -lc "rm -rf $GUEST_SRC $GUEST_RESULTS $GUEST_FIXTURE && mkdir -p $GUEST_RESULTS"
  tart exec "$CLONE" /bin/zsh -lc "cp -R '/Volumes/My Shared Files/run/src' $GUEST_SRC"
# The fixture the spike re-derivations (#0395 round 2) drive:
#   - four commits with distinctive subjects (History rows to select;
#     the chain's third commit has a non-root parent, so both
#     Swap-with-Child and Swap-with-Parent are enabled for it), each
#     touching a DIFFERENT file so a reorder replays cleanly — #0383's
#     first run measured a swap that stopped on conflicts because every
#     commit appended to the same file;
#   - two extra local branches (the sidebar's Branches section and the
#     filter-narrowing assertions);
#   - a remote-tracking ref and a tag (the sidebar's Remotes and Tags
#     sections start collapsed and must expand to show them).
tart exec "$CLONE" /bin/zsh -lc \
  "git init --initial-branch=$GUEST_FIXTURE_BRANCH $GUEST_FIXTURE && \
   git -C $GUEST_FIXTURE config user.email uitest@example.invalid && \
   git -C $GUEST_FIXTURE config user.name 'Switchyard UI Test' && \
   cd $GUEST_FIXTURE && \
   printf 'root\n' > a.txt && git add a.txt && git commit -m '0382 root commit' && \
   printf 'second\n' > b.txt && git add b.txt && git commit -m '0382 second commit' && \
   printf 'third\n' > c.txt && git add c.txt && git commit -m '0382 third commit' && \
   printf 'tip\n' > d.txt && git add d.txt && git commit -m '0382 tip commit' && \
   git branch spike-side && git branch alpha-fork && git branch beta-older HEAD~2 && \
   git update-ref refs/remotes/origin/uitest-side HEAD && \
   git tag v0.1"
  local actual_branch
  actual_branch="$(tart exec "$CLONE" /bin/zsh -lc "git -C $GUEST_FIXTURE symbolic-ref --short HEAD" | tr -d '[:space:]')"
  [[ "$actual_branch" == "$GUEST_FIXTURE_BRANCH" ]] \
    || fail "[$label] guest fixture branch is '$actual_branch', expected '$GUEST_FIXTURE_BRANCH'"

  log "[$label] Running UI tests in the guest (XCUITest inside the VM only)"
  # pipefail so the rc is xcodebuild's exit, not tee's. The smoke test is
  # launch #1 of the fresh session; the spike's launch is #2 — from a
  # session's third launch the app opens no window at all.
  set +e
  local rc
  tart exec "$CLONE" /bin/zsh -lc \
    "set -o pipefail; cd $GUEST_SRC && xcodebuild -project Switchyard.xcodeproj -scheme 'Switchyard UITests' \
       -destination 'platform=macOS' \
       CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_APP_SANDBOX=NO \
       -resultBundlePath $GUEST_RESULTS/UITests-$label.xcresult test \
       -only-testing:'SwitchyardUITests/SmokeUITests' \
       $tests 2>&1 | tee $GUEST_RESULTS/xcodebuild-$label.log"
  rc=$?
  set -e
  (( rc > TEST_RC )) && TEST_RC=$rc

  local out="$RESULTS_DIR/$label"
  mkdir -p "$out"
  log "[$label] Pulling results into $out"
  tart exec "$CLONE" /bin/zsh -lc "tar -C $GUEST_RESULTS -cf - ." | tar -x -C "$out"
  grep -E 'Test Case .* (passed|failed)|TEST (SUCCEEDED|FAILED)' \
    "$out/xcodebuild-$label.log" | tail -6 || true

  tart stop "$CLONE" >/dev/null 2>&1 || true
  tart delete "$CLONE" >/dev/null 2>&1 || true
  CLONE=""
}

# Which spikes to run: all four by default; the arguments filter by issue
# number (e.g. `./run-ui-tests-vm.sh 0383` runs just that one) so a round
# can spend its command budget one clone at a time.
run_spike_if_selected() {
  local number="$1"; shift
  if [[ -z "$SPIKE_FILTER" ]] || [[ "$SPIKE_FILTER" == "$number" ]]; then
    run_spike "$number" "spike-$number" SmokeUITests "$1"
  fi
}
run_spike_if_selected 0382 Spike0382ContextKeysUITests
run_spike_if_selected 0383 Spike0383ArrowsUITests
run_spike_if_selected 0385 Spike0385AlertLiveUpdateUITests
run_spike_if_selected 0386 Spike0386SectionsCollapseUITests
run_spike_if_selected 0401 Spike0401SidebarBranchFocusUITests

print ""
if (( TEST_RC == 0 )); then
  log "RESULT: TEST SUCCEEDED (exit 0)"
else
  log "RESULT: TEST FAILED (exit $TEST_RC)"
fi
for log_file in "$RESULTS_DIR"/spike-*/xcodebuild-*.log; do
  [[ -f "$log_file" ]] || continue
  print "--- $(basename "$log_file")"
  grep -E 'Test Case .* (passed|failed)|TEST (SUCCEEDED|FAILED)' "$log_file" | tail -8 || true
done
print ""
log "Results and bundles: $RESULTS_DIR/"

exit "$TEST_RC"
