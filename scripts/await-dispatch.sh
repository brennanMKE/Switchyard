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
PATTERN="dispatch-issue.sh ${ISSUE}"

running() { pgrep -f "$PATTERN" >/dev/null 2>&1 }

if ! running; then
  print "await: no dispatch running for #$ISSUE — it has finished (or never started)."
  exit 0
fi

print "await: #$ISSUE running; blocking up to ${BUDGET}s (exit 75 = call me again)"
elapsed=0
while (( elapsed < BUDGET )); do
  sleep "$POLL"
  elapsed=$(( elapsed + POLL ))
  if ! running; then
    print "await: #$ISSUE finished after ~${elapsed}s of this call. Verify now."
    exit 0
  fi
done

print "await: #$ISSUE still running after ${BUDGET}s. CALL THIS SCRIPT AGAIN — do not report yet."
exit 75
