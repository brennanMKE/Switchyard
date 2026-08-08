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
# silent for 420s, so a live round cannot be quieter than that and survive.

running_by_pattern() { pgrep -f "$PATTERN" >/dev/null 2>&1 }

# The authoritative signal, when it exists. `dispatch-issue.sh` writes
# `.switchyard-runs/NNNN-roundN.done` from an EXIT trap, so it appears on every
# exit path including a timeout kill and the no-changes exit 7 — and it is
# removed at start, so it can only describe the current round. Everything below
# this is inference; this is a fact.
done_file() {
  local -a f
  f=( .switchyard-runs/${ISSUE}-round*.done(N) )
  (( ${#f} )) && print -r -- "${f[1]}"
}

# Newest mtime across this issue's round log and suite capture, as an age in
# seconds. 999999 when neither exists yet.
output_age() {
  local -a files
  files=( .switchyard-runs/${ISSUE}-round*.log(N) .switchyard-runs/${ISSUE}-round*-suite.txt(N) )
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
    # No output yet. The round is still starting up — give it a grace window
    # rather than declaring a just-launched dispatch dead.
    (( SECONDS < 180 )) && return 0
    return 1
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
