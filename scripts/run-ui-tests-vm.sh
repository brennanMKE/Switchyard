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
#      short (the machine's observer frees what it can), and clones left
#      by DEAD runs swept — a clone whose owning run is still alive is never
#      touched (#0424).
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
#   6. Cleanup on EXIT, on any errexit failure and on HUP/INT/TERM (traps —
#      see cleanup_and_exit for why EXIT alone is not enough, #0460): stop
#      and delete the clone, remove the export. SIGKILL skips every trap; the
#      next run's #0424 sweep reclaims that clone.
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
GUEST_MAP_FIXTURE="/Users/$GUEST_USER/uitest-map-repo"
GUEST_CHANGES_FIXTURE="/Users/$GUEST_USER/uitest-changes-repo"
GUEST_REMOTE_FIXTURE="/Users/$GUEST_USER/uitest-remote"
GUEST_STASH_FIXTURE="/Users/$GUEST_USER/uitest-stash-repo"
GUEST_SWITCH_FIXTURE="/Users/$GUEST_USER/uitest-switch"
GUEST_BLAME_FIXTURE="/Users/$GUEST_USER/uitest-blame-repo"
GUEST_REMOTES_FIXTURE="/Users/$GUEST_USER/uitest-remotes"
GUEST_DIFFOPTS_FIXTURE="/Users/$GUEST_USER/uitest-diffopts-repo"
GUEST_LARGE_FIXTURE="/Users/$GUEST_USER/uitest-large-repo"
GUEST_COMPOSER_FIXTURE="/Users/$GUEST_USER/uitest-composer-repo"
GUEST_HISTORY_FIXTURE="/Users/$GUEST_USER/uitest-history"
GUEST_FIXUP_FIXTURE="/Users/$GUEST_USER/uitest-fixup-repo"
GUEST_MERGE_FIXTURE="/Users/$GUEST_USER/uitest-merge"
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

typeset -g CLEANED_UP=0

cleanup() {
  local rc=${1:-$?}
  (( CLEANED_UP )) && return 0
  CLEANED_UP=1
  trap - EXIT ZERR INT TERM HUP
  set +e
  log "Cleaning up (exit $rc)"
  # Release whatever spike-scoped lease is open. Not fatal if missed: leases
  # are pid-stamped and the next acquire prunes ours.
  if [[ -n "${LEASE_ID:-}" ]]; then
    tart-lease release --id "$LEASE_ID" 2>/dev/null || true
    LEASE_ID=""
  fi
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
  if [[ -n "$CLONE" ]]; then
    tart stop "$CLONE" >/dev/null 2>&1 || true
    tart delete "$CLONE" >/dev/null 2>&1 || true
  fi
  rm -rf "$EXPORT"
}

# #0460: zsh 5.9 does NOT run the EXIT trap when errexit fires inside a
# function, nor when a trap handler calls `exit` while a function is running
# (measured: `f(){ false; }; f` under `set -e` exits 1 with the EXIT trap
# silent). Every clone lives inside start_guest/run_spike/run_launch_smoke, so
# the EXIT trap alone leaked the clone on any failing guest command. Errors
# and signals therefore clean up explicitly and then exit.
cleanup_and_exit() {
  local rc=$1
  # A failing command inside $(...) runs this in the subshell: leave the clone
  # to the parent, which fails on the substitution's status next.
  (( ZSH_SUBSHELL == 0 )) || exit "$rc"
  cleanup "$rc"
  exit "$rc"
}
# ZERR fires on every non-zero status, including inside the deliberate
# `set +e` windows around xcodebuild — those must fall through untouched.
on_zerr() {
  local rc=$?
  [[ -o errexit ]] || return "$rc"
  cleanup_and_exit "$rc"
}
trap cleanup EXIT
trap on_zerr ZERR
trap 'cleanup_and_exit 129' HUP
trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM

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

# A SIGKILL (e.g. the OOM above) skips this script's trap, so sweep the
# clones earlier runs left behind — but ONLY those whose owning run is dead.
# Several sessions run this script at once (#0424: a second run's sweep used
# to delete the first run's live clone mid-boot), so a clone's name carries
# its owner: `switchyard-uitest-<YYYYMMDD>-<HHMMSS>-<pid>-<index>`, where
# <pid> is the owning run's `$$` (see start_guest).
#
# A run is alive when `kill -0` reaches its pid AND that process is still
# this script: pids recycle, and a recycled pid must not pin a dead run's
# clone forever. The pre-#0424 name `…-<HHMMSS>-<pid*10+index>` cannot be
# decoded, so such a clone is swept only once it is older than
# UITEST_LEGACY_MAX_AGE_SECS — no clone lives that long (the longest, the
# launch smoke's Debug build, is ~10 minutes). Everything else under
# `switchyard-uitest-` — the golden, a planner's hand-named scratch clone —
# is left alone, and nothing outside that prefix is even looked at, so
# another project's VMs are never candidates.
typeset -g UITEST_LEGACY_MAX_AGE_SECS=10800

# 0 when <pid> is a live run of this script.
uitest_run_is_live() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -q 'run-ui-tests-vm'
}

# Reads `tart list` on stdin and prints one line per `switchyard-uitest-*`
# VM: `sweep <name> <why>` or `keep <name> <why>`. Decides only; deletes
# nothing. <now> (epoch seconds) is a parameter so a test can pin it.
uitest_classify_clones() {
  local now="${1:-$(date +%s)}"
  local src name rest born
  while read -r src name rest; do
    [[ "$name" == switchyard-uitest-* ]] || continue
    if [[ "$name" == "$GOLDEN" || "$name" == switchyard-uitest-golden ]]; then
      print -r -- "keep $name golden"
    elif [[ "$name" =~ '^switchyard-uitest-[0-9]{8}-[0-9]{6}-([0-9]+)-[0-9]+$' ]]; then
      if uitest_run_is_live "$match[1]"; then
        print -r -- "keep $name owner-pid-$match[1]-alive"
      else
        print -r -- "sweep $name owner-pid-$match[1]-dead"
      fi
    elif [[ "$name" =~ '^switchyard-uitest-([0-9]{8})-([0-9]{6})-[0-9]+$' ]]; then
      born=$(date -j -f '%Y%m%d%H%M%S' "$match[1]$match[2]" +%s 2>/dev/null) || born="$now"
      if (( now - born > UITEST_LEGACY_MAX_AGE_SECS )); then
        print -r -- "sweep $name legacy-name-older-than-${UITEST_LEGACY_MAX_AGE_SECS}s"
      else
        print -r -- "keep $name legacy-name-too-young-to-judge"
      fi
    else
      print -r -- "keep $name not-a-run-clone"
    fi
  done
}

for verdict_line in ${(f)"$(tart list | uitest_classify_clones)"}; do
  read -r verdict name why <<< "$verdict_line"
  if [[ "$verdict" == sweep && "$name" != "$GOLDEN" ]]; then
    log "Sweeping stale clone: $name ($why)"
    tart stop "$name" >/dev/null 2>&1 || true
    tart delete "$name" >/dev/null 2>&1 || true
  else
    log "Leaving clone alone: $name ($why)"
  fi
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
typeset -g LEASE_ID=""

# Lease a slot, clone the golden, boot it with the export mounted, copy the
# source in and generate both fixture repositories. Sets CLONE and LEASE_ID.
start_guest() {
  local index="$1" label="$2"
  # Owner-stamped name, `switchyard-uitest-<YYYYMMDD>-<HHMMSS>-<pid>-<index>`:
  # the stale sweep reads <pid> back and deletes the clone only once this run
  # is dead (#0424), so a concurrent run never deletes it.
  # A lease per spike, not one for the whole run: the spikes are serial and a
  # full pass is ~20 minutes, which would shut every other repo out. Between
  # spikes another session can take the slot.
  # See Homelab protocols/tart-lease/PROTOCOL.md
  if command -v tart-lease >/dev/null; then
    LEASE_ID=$(tart-lease acquire --label "switchyard-$label" --pid $$)
  fi

  CLONE="switchyard-uitest-$(date +%Y%m%d-%H%M%S)-$$-$index"
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
  tart exec "$CLONE" /bin/zsh -lc "rm -rf $GUEST_SRC $GUEST_RESULTS $GUEST_FIXTURE $GUEST_MAP_FIXTURE $GUEST_CHANGES_FIXTURE $GUEST_REMOTE_FIXTURE $GUEST_STASH_FIXTURE $GUEST_SWITCH_FIXTURE $GUEST_BLAME_FIXTURE $GUEST_REMOTES_FIXTURE $GUEST_DIFFOPTS_FIXTURE $GUEST_LARGE_FIXTURE $GUEST_COMPOSER_FIXTURE $GUEST_COMPOSER_FIXTURE-template.txt $GUEST_HISTORY_FIXTURE $GUEST_FIXUP_FIXTURE && mkdir -p $GUEST_RESULTS"
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
  # #0410: the branch-map fixture, from its own script in the export.
  tart exec "$CLONE" /bin/zsh -lc "zsh $GUEST_SRC/scripts/uitest-fixtures/make-map-fixture.sh $GUEST_MAP_FIXTURE"
  # #0442: the Changes-view fixture — a dirty working tree.
  tart exec "$CLONE" /bin/zsh -lc "zsh $GUEST_SRC/scripts/uitest-fixtures/make-changes-fixture.sh $GUEST_CHANGES_FIXTURE"
  # #0455: the Fetch/Pull/Push fixture — a bare remote and four clones.
  tart exec "$CLONE" /bin/zsh -lc "zsh $GUEST_SRC/scripts/uitest-fixtures/make-remote-fixture.sh $GUEST_REMOTE_FIXTURE"
  # #0496: the stash fixture — two stashes and a clean tree.
  tart exec "$CLONE" /bin/zsh -lc "zsh $GUEST_SRC/scripts/uitest-fixtures/make-stash-fixture.sh $GUEST_STASH_FIXTURE"
  # #0512: the switch fixture — a dirty switch-main, three branches, a
  # remote branch and a tag.
  tart exec "$CLONE" /bin/zsh -lc "zsh $GUEST_SRC/scripts/uitest-fixtures/make-switch-fixture.sh $GUEST_SWITCH_FIXTURE"
  # #0520: the file history and blame fixture — a renamed file, edited in
  # the working tree.
  tart exec "$CLONE" /bin/zsh -lc "zsh $GUEST_SRC/scripts/uitest-fixtures/make-blame-fixture.sh $GUEST_BLAME_FIXTURE"
  # #0533: the remote-management fixture — a clone with a stale
  # remote-tracking branch, and a second bare repository to add.
  tart exec "$CLONE" /bin/zsh -lc "zsh $GUEST_SRC/scripts/uitest-fixtures/make-remotes-fixture.sh $GUEST_REMOTES_FIXTURE"
  # #0542: the diff options fixture — a re-indent, an edit and a
  # whitespace-only file in the working tree, and a whitespace-only commit.
  tart exec "$CLONE" /bin/zsh -lc "zsh $GUEST_SRC/scripts/uitest-fixtures/make-diffopts-fixture.sh $GUEST_DIFFOPTS_FIXTURE"
  # #0555: the large-history fixture — 6,002 commits and 1,000 tags.
  tart exec "$CLONE" /bin/zsh -lc "zsh $GUEST_SRC/scripts/uitest-fixtures/make-large-history-fixture.sh $GUEST_LARGE_FIXTURE"
  # #0568: the commit composer fixture — three authors, a commit.template
  # and a staged file.
  tart exec "$CLONE" /bin/zsh -lc "zsh $GUEST_SRC/scripts/uitest-fixtures/make-composer-fixture.sh $GUEST_COMPOSER_FIXTURE"
  # #0582: the Fixup with Parent fixture — four commits on fixup-main and a
  # staged file.
  tart exec "$CLONE" /bin/zsh -lc "zsh $GUEST_SRC/scripts/uitest-fixtures/make-fixup-fixture.sh $GUEST_FIXUP_FIXTURE"
  # #0578: the merge fixture — docs2 adds a file; ff/ and diverged/ shapes.
  tart exec "$CLONE" /bin/zsh -lc "rm -rf $GUEST_MERGE_FIXTURE && zsh $GUEST_SRC/scripts/uitest-fixtures/make-merge-fixture.sh $GUEST_MERGE_FIXTURE"
  # #0591: the history-operation fixture — main plus seven branches, one
  # repository copy per history spike class.
  tart exec "$CLONE" /bin/zsh -lc "zsh $GUEST_SRC/scripts/uitest-fixtures/make-history-ops-fixture.sh $GUEST_HISTORY_FIXTURE"
  local actual_branch
  actual_branch="$(tart exec "$CLONE" /bin/zsh -lc "git -C $GUEST_FIXTURE symbolic-ref --short HEAD" | tr -d '[:space:]')"
  [[ "$actual_branch" == "$GUEST_FIXTURE_BRANCH" ]] \
    || fail "[$label] guest fixture branch is '$actual_branch', expected '$GUEST_FIXTURE_BRANCH'"
}

# Stop and delete the clone, then give the lease back.
stop_guest() {
  tart stop "$CLONE" >/dev/null 2>&1 || true
  tart delete "$CLONE" >/dev/null 2>&1 || true
  CLONE=""

  if [[ -n "${LEASE_ID:-}" ]]; then
    tart-lease release --id "$LEASE_ID" 2>/dev/null || true
    LEASE_ID=""
  fi
}

run_spike() {
  local index="$1" label="$2"; shift 2
  local tests="" t
  for t in "$@"; do tests="$tests -only-testing:'SwitchyardUITests/$t'"; done
  start_guest "$index" "$label"

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

  stop_guest
}

# #0434: the launch smoke. XCUITest is not how a person starts the app, and
# it tolerated a Debug build that dies in dyld on an ordinary launch (see
# issues/0434.md for why). So, in its own clone: build the `Switchyard`
# scheme Debug and unsigned exactly as a person does, `open` it on the
# fixture, and require the process alive 10 s later with no new crash report
# in the guest's ~/Library/Logs/DiagnosticReports.
run_launch_smoke() {
  local label="launch-smoke"
  start_guest 0 "$label"
  log "[$label] Building the Debug Switchyard scheme unsigned and opening it"
  set +e
  local rc
  tart exec "$CLONE" /bin/zsh -lc "
    cd $GUEST_SRC
    xcodebuild build -project Switchyard.xcodeproj -scheme Switchyard -destination 'platform=macOS' \
      -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
      > $GUEST_RESULTS/xcodebuild-$label.log 2>&1 \
      || { echo 'LAUNCH SMOKE FAILED: xcodebuild build failed'; exit 1; }
    app=$GUEST_SRC/build/dd/Build/Products/Debug/Switchyard.app
    # The golden image runs with SIP disabled, and a SIP-disabled Mac waives the
    # library validation the hardened runtime implies: the #0434 build that died
    # on the host launched fine here. An EXPLICIT library-validation flag is
    # still enforced with SIP off (both measured 2026-09-27, issues/0434.md), so
    # a hardened main executable is re-signed ad-hoc with it and the guest then
    # refuses what a stock Mac refuses. Ad-hoc only: no identity, no keychain.
    if codesign -dv \$app 2>&1 | grep -q '^CodeDirectory.*flags=.*runtime'; then
      codesign --force --sign - --options library,runtime \$app \
        || { echo 'LAUNCH SMOKE FAILED: could not add library-validation'; exit 1; }
      echo 'hardened runtime present: library validation made explicit (SIP is off in the guest)'
    fi
    reports=\$HOME/Library/Logs/DiagnosticReports
    mkdir -p \$reports
    before=\$(ls \$reports | grep -c '^Switchyard')
    open -n \$app --args -uiTestRealSurfaces -uiTestRepository $GUEST_FIXTURE
    sleep 10
    alive=\$(pgrep -x Switchyard)
    after=\$(ls \$reports | grep -c '^Switchyard')
    cp \$reports/Switchyard*(N) $GUEST_RESULTS/
    pkill -x Switchyard
    echo \"pid=\${alive:-none} crash-reports-before=\$before after=\$after\"
    if [[ -n \$alive ]] && (( after == before )); then
      echo 'LAUNCH SMOKE PASSED'
    else
      echo 'LAUNCH SMOKE FAILED: the app died or left a crash report'
      exit 1
    fi
  " 2>&1 | tee "$EXPORT/launch-smoke.out"
  rc=${pipestatus[1]}
  set -e
  (( rc > TEST_RC )) && TEST_RC=$rc

  local out="$RESULTS_DIR/$label"
  mkdir -p "$out"
  cp "$EXPORT/launch-smoke.out" "$out/launch-smoke.out"
  tart exec "$CLONE" /bin/zsh -lc "tar -C $GUEST_RESULTS -cf - ." | tar -x -C "$out"

  stop_guest
}

# Which spikes to run: all four by default; the arguments filter by issue
# number (e.g. `./run-ui-tests-vm.sh 0383` runs just that one) so a round
# can spend its command budget one clone at a time.
# An optional third argument suffixes the results label, so two classes under
# one issue number keep separate results (#0435) instead of the second
# overwriting the first's `spike-NNNN/` bundle and log.
# An optional fourth argument names a group (#0591: `history`), so
# `./run-ui-tests-vm.sh history` runs every spike in it, each in its own clone.
run_spike_if_selected() {
  local number="$1"; shift
  if [[ -z "$SPIKE_FILTER" ]] || [[ "$SPIKE_FILTER" == "$number" ]] \
     || [[ -n "${3:-}" && "$SPIKE_FILTER" == "$3" ]]; then
    run_spike "$number" "spike-$number${2:+-$2}" SmokeUITests "$1"
  fi
}
if [[ -z "$SPIKE_FILTER" ]] || [[ "$SPIKE_FILTER" == "launch" ]]; then
  run_launch_smoke
fi
run_spike_if_selected 0382 Spike0382ContextKeysUITests
run_spike_if_selected 0383 Spike0383ArrowsUITests
run_spike_if_selected 0385 Spike0385AlertLiveUpdateUITests
run_spike_if_selected 0386 Spike0386SectionsCollapseUITests
run_spike_if_selected 0401 Spike0401SidebarBranchFocusUITests
run_spike_if_selected 0399 Spike0399CompactGraphRowsUITests
run_spike_if_selected 0400 Spike0400GraphScreenshotUITests
run_spike_if_selected 0406 Spike0406CommitChangesWindowUITests
run_spike_if_selected 0403 Spike0403DetailWithoutDiffUITests
run_spike_if_selected 0402 Spike0402FilterHighlightsGraphUITests
run_spike_if_selected 0415 Spike0415BranchMapUITests
run_spike_if_selected 0416 Spike0416OpenShowsRepositoryUITests
run_spike_if_selected 0417 Spike0417RepositoryTabsUITests
run_spike_if_selected 0427 Spike0427BranchMapFoldUITests
run_spike_if_selected 0429 Spike0429BranchMapRecencyUITests
run_spike_if_selected 0430 Spike0430BranchMapMergedUITests
run_spike_if_selected 0435 Spike0435LaunchArgumentOpenUITests launch-argument
run_spike_if_selected 0435 Spike0435PlainLaunchOpenUITests plain
run_spike_if_selected 0448 Spike0448UndoReachesJournalUITests
run_spike_if_selected 0443 Spike0443ChangesListUITests
run_spike_if_selected 0444 Spike0444StageHunkUITests
run_spike_if_selected 0445 Spike0445CommitUITests
run_spike_if_selected 0446 Spike0446WorkingChangesRowUITests
run_spike_if_selected 0447 Spike0447RefreshOnActivateUITests
run_spike_if_selected 0457 Spike0457FetchPullUITests fetch-pull
run_spike_if_selected 0457 Spike0457PullRefusedUITests refused
run_spike_if_selected 0458 Spike0458CancelPushUITests
run_spike_if_selected 0459 Spike0459PushUITests
run_spike_if_selected 0466 Spike0466AmendUITests amend
run_spike_if_selected 0466 Spike0466AmendPushedUITests pushed
run_spike_if_selected 0471 Spike0471DiscardFilesUITests
run_spike_if_selected 0472 Spike0472DiscardHunkUITests
run_spike_if_selected 0480 Spike0480StageLinesUITests
run_spike_if_selected 0494 Spike0494StashChangesUITests
run_spike_if_selected 0496 Spike0496StashListUITests
run_spike_if_selected 0512 Spike0512SwitchBranchUITests
run_spike_if_selected 0520 Spike0520FileHistoryBlameUITests
run_spike_if_selected 0525 Spike0525HistorySearchUITests
run_spike_if_selected 0533 Spike0533RemoteManagementUITests
run_spike_if_selected 0542 Spike0542DiffOptionsUITests
run_spike_if_selected 0555 Spike0555LargeHistoryUITests
run_spike_if_selected 0556 Spike0556MatchStepUITests
run_spike_if_selected 0557 Spike0557MapArrowsUITests
run_spike_if_selected 0568 Spike0568ComposerUITests composer
run_spike_if_selected 0568 Spike0568DraftKeptUITests draft
run_spike_if_selected 0570 Spike0570UndoAfterCommitUITests
run_spike_if_selected 0571 Spike0571SidebarStatusUITests
run_spike_if_selected 0572 Spike0572StagedSelectionUITests
run_spike_if_selected 0574 Spike0574HeaderAndDiffLayoutUITests
run_spike_if_selected 0573 Spike0573RecoverWindowUITests
run_spike_if_selected 0578 Spike0578MergeFastForwardableUITests ff history
run_spike_if_selected 0578 Spike0578MergeDivergedUITests diverged history
run_spike_if_selected 0582 Spike0582FixupWithParentUITests "" history

# #0590: the history-operation suite — `./scripts/run-ui-tests-vm.sh history`.
run_spike_if_selected 0591 Spike0591GitAssertionsUITests "" history
run_spike_if_selected 0592 Spike0592MergeFastForwardableUITests ff history
run_spike_if_selected 0592 Spike0592MergeDivergedUITests diverged history
run_spike_if_selected 0592 Spike0592MergeConflictUITests conflict history
run_spike_if_selected 0593 Spike0593RebaseOntoUITests clean history
run_spike_if_selected 0593 Spike0593RebaseConflictUITests conflict history
run_spike_if_selected 0594 Spike0594CherryPickUITests cherry-pick history
run_spike_if_selected 0594 Spike0594RevertUITests revert history
run_spike_if_selected 0595 Spike0595SquashUITests squash history
run_spike_if_selected 0595 Spike0595FixupTipUITests fixup history
# run_spike_if_selected 0596 Spike0596SwapWithParentUITests swap-parent history
# run_spike_if_selected 0596 Spike0596SwapWithChildUITests swap-child history
# run_spike_if_selected 0596 Spike0596DeleteUITests delete history
# run_spike_if_selected 0597 Spike0597EditMessageUITests edit-message history
# run_spike_if_selected 0597 Spike0597SplitUITests split history
# run_spike_if_selected 0598 Spike0598SetBranchTipUITests set-tip history
# run_spike_if_selected 0598 Spike0598CreateBranchAndTagUITests refs history

print ""
if (( TEST_RC == 0 )); then
  log "RESULT: TEST SUCCEEDED (exit 0)"
else
  log "RESULT: TEST FAILED (exit $TEST_RC)"
fi
if [[ -f "$RESULTS_DIR/launch-smoke/launch-smoke.out" ]]; then
  print -r -- "--- launch-smoke"
  grep -E '^pid=|LAUNCH SMOKE|library validation' "$RESULTS_DIR/launch-smoke/launch-smoke.out" || true
fi
for log_file in "$RESULTS_DIR"/spike-*/xcodebuild-*.log(N); do
  [[ -f "$log_file" ]] || continue
  print -r -- "--- $(basename "$log_file")"
  grep -E 'Test Case .* (passed|failed)|TEST (SUCCEEDED|FAILED)' "$log_file" | tail -8 || true
done
print ""
log "Results and bundles: $RESULTS_DIR/"

exit "$TEST_RC"
