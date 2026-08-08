#!/usr/bin/env zsh
#
# await-dispatch.sh NNNN — block until *that issue's* dispatch finishes.
#
# Exit 0   the dispatch has finished; go verify
# Exit 75  still running after this call's budget; CALL THIS SCRIPT AGAIN
#
# Why this exists: a dispatcher subagent's turn ends the moment it emits text
# without a tool call. Twice a dispatcher wrote "waiting for the dispatch to
# exit" and stopped, leaving a 20-minute round unwatched. Adding "do not stop"
# to the prompt did not work — the agent is not choosing to stop, it is writing
# a sentence that reads to itself like a status update.
#
# So waiting stops being a decision. This blocks inside a tool call and returns
# a code: the agent either has a result or must call again. There is no state in
# which "wait" is something it can merely intend.
#
# The issue number is REQUIRED. The first version matched any `opencode run`,
# which meant two concurrent dispatches each blocked until BOTH finished —
# #0100's wait sat for nine minutes after its own round had exited, because
# #0099 was still going. Watch the harness process for this issue instead: it
# `wait`s on its own opencode child, so its exit is exactly this round ending.

set -u

ISSUE="${1:-}"
if [[ -z "$ISSUE" ]]; then
  print -u2 "usage: await-dispatch.sh NNNN
The issue number is required — waiting on 'any dispatch' makes concurrent
rounds block on each other."
  exit 1
fi

BUDGET=${BUDGET:-540}     # seconds per call; the foreground tool limit is 600
POLL=10
QUIET_LIMIT=${QUIET_LIMIT:-450}   # this issue's own output silent this long = over
PATTERN="dispatch-issue.sh ${ISSUE}"

# WHERE THE ROUND'S OUTPUT ACTUALLY IS. `dispatch-issue.sh` runs in the issue's
# worktree and writes `.switchyard-runs/` THERE. This script previously globbed
# that path relative to the caller's cwd, so calling it from the primary checkout
# — which is the natural thing to do, and what the dispatcher prompt said —
# found no files at all, reported `silent for 999999s`, and after the 180s
# start-up grace declared a round finished that ran for another 105 seconds.
# #0033's dispatcher caught it only by falling back to the live opencode PID;
# trusting it would have meant reviewing an empty worktree and calling the round
# a failure.
# Pick the directory that actually holds THIS ISSUE's files, not merely the
# first directory that exists. The primary checkout has its own
# `.switchyard-runs` full of other issues' rounds, so an existence test alone
# still resolves to the wrong place and reproduces the original bug.
RUNS_DIR=".switchyard-runs"
for candidate in ".switchyard-runs" "${0:A:h:h:h}/switchyard-${ISSUE}/.switchyard-runs"; do
  typeset -a probe
  probe=( ${candidate}/${ISSUE}-round*(N) )
  (( ${#probe} )) && { RUNS_DIR="$candidate"; break }
done

# `pgrep -f` alone is not a reliable liveness test, and this cost two dispatchers
# more than an hour each on 2026-08-07 (#0019 and #0016). When the round is
# started as a background tool call, a wrapper process keeps the whole command
# string — including "dispatch-issue.sh 0016" — in its argv after the real round
# has exited. `running()` then never goes false and the agent loops forever on a
# round that finished, while its worktree sits ready for review.
#
# So liveness needs a second, independent signal, and it must be **this issue's**
# signal. A global `pgrep -f 'opencode run'` will not do: a concurrent round on
# another issue keeps it true, which is precisely the cross-issue coupling this
# script was written to avoid — #0100 once waited nine minutes on #0099. That
# mistake was made again while fixing this and caught by a control.
#
# The per-issue signal is the round's own output. `dispatch-issue.sh` writes
# `.switchyard-runs/NNNN-roundN.log` while the model runs and
# `NNNN-roundN-suite.txt` while it captures the suite afterwards. If neither has
# been touched for QUIET_LIMIT seconds, the round is over — and that is safe to
# assert because the harness's own stall watchdog kills any round whose log goes
# silent for STALL seconds, so a live round cannot be quieter than that and
# survive.
#
# THIS VALUE IS COUPLED TO dispatch-issue.sh's STALL AND MUST STAY ABOVE IT.
# Keep roughly STALL + 50, and move it whenever STALL moves. It went 450 -> 950
# when STALL went 420 -> 900 for PARALLEL 4, and back to 450 when the dispatch
# ceiling dropped to 1. Left low against a high STALL it would declare a live
# round finished mid-prefill — the exact false-completion this file exists to
# eliminate.

running_by_pattern() { pgrep -f "$PATTERN" >/dev/null 2>&1 }

# The authoritative signal, when it exists. `dispatch-issue.sh` writes
# `.switchyard-runs/NNNN-roundN.done` from an EXIT trap, so it appears on every
# exit path including a timeout kill and the no-changes exit 7 — and it is
# removed at start, so it can only describe the current round. Everything below
# this is inference; this is a fact.
# Newest first: `om` orders by mtime. Belt and braces alongside
# dispatch-issue.sh clearing every prior round's record at start -- a stale
# record from round 1 once made this report round 2 as finished before it had
# even begun.
done_file() {
  local -a f
  f=( ${RUNS_DIR}/${ISSUE}-round*.done(Nom) )
  (( ${#f} )) && print -r -- "${f[1]}"
}

# Newest mtime across this issue's round log and suite capture, as an age in
# seconds. 999999 when neither exists yet.
output_age() {
  local -a files
  files=( ${RUNS_DIR}/${ISSUE}-round*.log(N) ${RUNS_DIR}/${ISSUE}-round*-suite.txt(N) )
  (( ${#files} )) || { print 999999; return }
  local newest=0 m
  for f in $files; do
    m=$(stat -f %m "$f" 2>/dev/null) || continue
    (( m > newest )) && newest=$m
  done
  (( newest )) || { print 999999; return }
  print $(( $(date +%s) - newest ))
}

# Returns 0 while the round still looks alive.
running() {
  # A completion record ends the question outright, whatever any process or
  # mtime suggests.
  [[ -n "$(done_file)" ]] && return 1
  running_by_pattern || return 1
  local age; age=$(output_age)
  if (( age == 999999 )); then
    # No output found. Two very different situations share this symptom, and
    # conflating them is what produced the false completion on #0033:
    #
    #   (a) the round has not written anything yet — genuinely starting up;
    #   (b) we are looking in the wrong directory, or the files were removed.
    #
    # In case (b) a live round is invisible to us. Since `running_by_pattern`
    # already told us a matching process EXISTS, absence of output is evidence
    # about our search path, not about the round. Never conclude "finished"
    # from it — keep waiting and say why. Only the `.done` record, checked
    # above, may end the wait when a process is still matching.
    (( SECONDS < 180 )) && return 0
    print -u2 "await: #$ISSUE — a matching process is alive but NO output was found in
       '$RUNS_DIR'. That is a search-path problem, not a finished round.
       Still waiting. Run this script from the issue's worktree if it persists."
    return 0
  fi
  (( age < QUIET_LIMIT )) && return 0
  return 1
}

finished_note() {
  local d; d=$(done_file)
  if [[ -n "$d" ]]; then
    print "await: #$ISSUE completion record — $d"
    cat "$d"
    return
  fi
  if running_by_pattern; then
    print "await: #$ISSUE — this issue's own output has been silent for $(output_age)s."
    print "       The dispatch process pattern still matches, but that is a"
    print "       stale wrapper argv, not a live round. Treating it as finished."
  fi
}

if ! running; then
  print "await: no dispatch running for #$ISSUE — it has finished (or never started)."
  finished_note
  exit 0
fi

print "await: #$ISSUE running; blocking up to ${BUDGET}s (exit 75 = call me again)"
elapsed=0
while (( elapsed < BUDGET )); do
  sleep "$POLL"
  elapsed=$(( elapsed + POLL ))
  if ! running; then
    print "await: #$ISSUE finished after ~${elapsed}s of this call. Verify now."
    finished_note
    exit 0
  fi
done

print "await: #$ISSUE still running after ${BUDGET}s. CALL THIS SCRIPT AGAIN — do not report yet."
print "await: (this issue's output has been idle $(output_age)s; limit ${QUIET_LIMIT}s)"
exit 75
