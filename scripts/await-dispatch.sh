#!/usr/bin/env zsh
#
# await-dispatch.sh — block until the running OpenCode dispatch finishes.
#
# Exit 0   the dispatch has finished; go verify
# Exit 75  still running after this call's budget; CALL THIS SCRIPT AGAIN
#
# Why this exists: a dispatcher subagent's turn ends the moment it emits text
# without a tool call. Twice now one has written "waiting for the dispatch to
# exit" and stopped, leaving a 20-minute round unwatched. Adding "do not stop"
# to the prompt did not work — the agent is not choosing to stop, it is writing
# a sentence that reads to itself like a status update.
#
# So waiting stops being a decision. This blocks inside a tool call and returns
# a code. The agent either has a result or must call again; there is no state in
# which "wait" is something it can merely intend.
#
# The budget is under the 10-minute foreground tool limit, so a long round takes
# several calls rather than one that gets killed.

set -u

BUDGET=${BUDGET:-540}     # seconds per call; the tool limit is 600
POLL=10

if ! pgrep -f 'opencode run' >/dev/null 2>&1; then
  print "await: no dispatch running — it has finished (or never started)."
  exit 0
fi

print "await: dispatch running; blocking up to ${BUDGET}s (exit 75 = call me again)"
elapsed=0
while (( elapsed < BUDGET )); do
  sleep "$POLL"
  elapsed=$(( elapsed + POLL ))
  if ! pgrep -f 'opencode run' >/dev/null 2>&1; then
    print "await: dispatch finished after ~${elapsed}s of this call. Verify now."
    exit 0
  fi
done

print "await: still running after ${BUDGET}s. CALL THIS SCRIPT AGAIN — do not report yet."
exit 75
