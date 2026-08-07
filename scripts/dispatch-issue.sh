#!/bin/zsh
# Dispatch one issue to OpenCode running the local model.
#
#   scripts/dispatch-issue.sh 0012 [--round N] [--model ornith|sonnet] [--timeout SECS]
#                                  [--stall SECS] [--force]
#
# Guards, in order of how often they matter:
#   - hard wall-clock timeout, because the model has looped before and there is
#     no `timeout` binary on this Mac
#   - round cap, so a task that is not converging escalates to a human instead
#     of burning an afternoon
#   - clean-tree precondition, so the diff produced by a round is attributable
#     to that round
#   - no-progress detection, because a run that "succeeds" and changes nothing
#     is a failure that reports as success
#
# The model implements. It does not commit and it does not set status. Review
# and status are the reviewing model's job — see issues/Issues.md.

set -u
setopt ERR_EXIT PIPE_FAIL

REPO_ROOT="${0:A:h:h}"
cd "$REPO_ROOT"

MAX_ROUNDS=3
TIMEOUT=1800
# Kill a round that has written nothing to its log for this long. A working
# round appends constantly; silence this long means a hung request.
STALL=420
STALL_POLL=30
# Which implementer. `ornith` is the local model and the default; `sonnet` is
# billed and is for the work Ornith has repeatedly failed at -- Package.swift,
# the Xcode project, and anything about the environment. See CLAUDE.md.
MODEL_CHOICE=ornith
ROUND=1
FORCE=0
ISSUE=""

while (( $# )); do
  case "$1" in
    --round)   ROUND="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --stall)   STALL="$2"; shift 2 ;;
    --model)   MODEL_CHOICE="$2"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *)         ISSUE="$1"; shift ;;
  esac
done

die() { print -u2 "dispatch: $1"; exit "${2:-1}" }

[[ -n "$ISSUE" ]] || die "usage: dispatch-issue.sh NNNN [--round N] [--timeout SECS] [--force]"
[[ "$ISSUE" =~ '^[0-9]{4}$' ]] || die "issue must be 4 digits, got '$ISSUE'"
[[ -f "issues/$ISSUE.md" ]] || die "issues/$ISSUE.md does not exist"

# Every mechanical check derived from a past failed round lives in
# preflight-issue.sh, and each one is there because a round was already lost to
# the thing it looks for. Refusing to dispatch a known-defective issue is the
# cheapest guard in the harness: it costs a second, and the alternative costs a
# twenty-minute round plus a review. See docs/review-failures.md.
"$REPO_ROOT/scripts/preflight-issue.sh" "$ISSUE" || die \
"preflight rejected issues/$ISSUE.md (above). Fix the issue text, commit the
planning update, then dispatch. Do not dispatch an issue already known to be
defective — the round will only rediscover it." 9

# Re-dispatching an unchanged prompt produces an unchanged result. issues/Issues.md
# has said so since #0070 round 2; nothing enforced it. #0098 round 2 only
# converged because the issue was genuinely rewritten first.
if (( ROUND > 1 && ! FORCE )); then
  PREV_LOG=".switchyard-runs/$ISSUE-round$((ROUND-1)).log"
  if [[ -f "$PREV_LOG" ]]; then
    [[ "issues/$ISSUE.md" -nt "$PREV_LOG" ]] || die \
"issues/$ISSUE.md has not changed since round $((ROUND-1)) ran.
Re-dispatching an unchanged prompt re-runs a prompt already proven not to work.
Write a '## Review' section explaining what to do differently, or split the
issue. See docs/review-failures.md." 10
    grep -q '^## Review' "issues/$ISSUE.md" || die \
"round $ROUND, but issues/$ISSUE.md has no '## Review' section.
The model has no way to know what went wrong last round.

Add one. If the previous round produced nothing -- a timeout, an empty tree --
say exactly that under the heading, along with what has changed since so this
round will not repeat it. 'Nothing to review' is itself the review, and the
model needs to read it. Do NOT reach for --force; the heading costs a minute
and the round costs twenty." 10
  fi
fi

if (( ROUND > MAX_ROUNDS && ! FORCE )); then
  die "round $ROUND exceeds the cap of $MAX_ROUNDS. The task is not converging.
Rewrite the issue with more specific guidance, split it, or take it back.
Override with --force only if you know why the extra round will differ." 3
fi

# Work happens on a per-issue branch. main is never touched directly, and the
# branch keeps every round's commit as an artifact of how the work went.
BRANCH="issue/$ISSUE"
CURRENT=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT" != "$BRANCH" ]]; then
  die "on branch '$CURRENT', expected '$BRANCH'.
Start the issue with:  git switch -c $BRANCH
Or switch back with:   git switch $BRANCH" 8
fi

# A round's diff is only meaningful against a clean starting point. Between
# rounds, commit the previous round to the branch — those commits are the
# artifact record, so do not squash them away here.
if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is dirty. Commit the previous round to $BRANCH (or discard it)
so this round's diff is attributable." 4
fi

command -v opencode >/dev/null || die "opencode not found on PATH" 5
curl -sf -m 5 http://127.0.0.1:1234/v1/models >/dev/null \
  || die "LM Studio is not answering on 127.0.0.1:1234. Start it and load the model." 6

case "$MODEL_CHOICE" in
  ornith)
    MODEL=$(curl -sf -m 5 http://127.0.0.1:1234/v1/models \
      | sed -n 's/.*"id": "\([^"]*\)".*/\1/p' | head -1)
    OPENCODE_MODEL_ARG=()
    [[ -n "$MODEL" ]] || die "LM Studio is not answering on 127.0.0.1:1234. Start it, or pass
--model sonnet." 9
    ;;
  sonnet)
    MODEL="anthropic/claude-sonnet-5"
    OPENCODE_MODEL_ARG=(--model "$MODEL")
    print "dispatch: NOTE -- this round is BILLED. Ornith is $0.00; Sonnet is not."
    ;;
  *)
    die "unknown --model '$MODEL_CHOICE'. Use ornith (local, default) or sonnet (billed)." 2
    ;;
esac
LOG_DIR=".switchyard-runs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$ISSUE-round$ROUND.log"
BASE_SHA=$(git rev-parse HEAD)

read -r -d '' PROMPT <<EOF || true
Work issue $ISSUE. Read issues/$ISSUE.md, then issues/Issues.md, then AGENTS.md.

This is round $ROUND of at most $MAX_ROUNDS. If a previous round left review
feedback in the issue's "## Review" section, that feedback is the task.

Rules for this run, which override anything in the issue that disagrees:
  1. Implement only what issue $ISSUE asks for. Do not start another issue.
  2. Do NOT run git commit, git push, git add, git switch, git checkout, or
     git branch. You are already on the correct branch. Leave changes in the
     working tree for review.
  3. Do NOT change the issue's Status row. Review decides that.
  4. Run the verification command the issue names and paste its real output.
     Never claim a test passed without output showing it ran.
  5. If you are blocked, or find yourself repeating an action that already
     failed, STOP and report what blocked you. A clear stop is a good outcome.
     Repeating a failing command is not.
  6. Your sandbox AUTO-REJECTS writes outside this worktree: /tmp, /var/tmp,
     \$TMPDIR, and anything under ~ that is not here. Put every scratch file,
     probe and throwaway git fixture under build/ in this worktree. It is
     already gitignored. THREE rounds have now been lost to this exact
     rejection. Note the asymmetry: swift test is NOT sandboxed, so
     FixtureRepository's own temp directories work fine — only commands you
     run yourself are restricted.
  7. If a command is rejected or a tool call fails twice the same way, change
     approach; do not retry it. If the write tool fails twice on one file,
     create it with a shell heredoc instead: cat > path/File.swift <<'SWIFT'
     ... SWIFT. Never end your turn by describing steps you have not run.
  8. Do NOT spawn a subagent — no Explore, no Task, no delegation of any kind.
     The issue names every file, type and signature you need. Four of the last
     five failed rounds hung on that handoff and produced nothing at all.
  9. Read the files the issue names, then START EDITING. Do not survey the
     repository first. One round read twelve files without writing a line,
     filled its context to 49k, was compacted, and died -- it had treated a
     fully-specified issue as a research task. If you find yourself reading a
     file the issue did not name, stop and ask whether you already have what
     you need.

Finish with a short report: what you changed, what you ran, what it printed,
and anything you could not do.
EOF

print "dispatch: issue $ISSUE, round $ROUND/$MAX_ROUNDS, model ${MODEL:-unknown} (${MODEL_CHOICE}), timeout ${TIMEOUT}s, stall ${STALL}s"
print "dispatch: log -> $LOG"

START=$SECONDS
opencode run "${OPENCODE_MODEL_ARG[@]}" "$PROMPT" >"$LOG" 2>&1 &
RUN_PID=$!

# Two watchdogs. The wall-clock one bounds a round that is working but slow;
# the stall one bounds a round that has stopped producing anything at all.
#
# #0120 round 1 hung on an inference request that never returned -- a session
# row written with 0/0 tokens and no finish reason -- and then sat silent for
# 27 minutes until the 1800s guard fired. OpenCode's own `chunkTimeout` did not
# fire. The log's mtime is the cheap, reliable signal: a live round appends to
# it constantly.
( sleep "$TIMEOUT"
  kill -TERM "$RUN_PID" 2>/dev/null
  sleep 10
  kill -KILL "$RUN_PID" 2>/dev/null ) &
WATCHDOG=$!

( while kill -0 "$RUN_PID" 2>/dev/null; do
    sleep "$STALL_POLL"
    [[ -f "$LOG" ]] || continue
    LAST=$(stat -f %m "$LOG" 2>/dev/null || print 0)
    NOW=$(date +%s)
    if (( NOW - LAST >= STALL )); then
      print -u2 "\ndispatch: STALLED -- no log output for ${STALL}s. Killing."
      print -u2 "dispatch: this is the hung-inference shape, not a slow round. See #0120 round 1."
      kill -TERM "$RUN_PID" 2>/dev/null
      sleep 10
      kill -KILL "$RUN_PID" 2>/dev/null
      break
    fi
  done ) &
STALLDOG=$!

STATUS=0
wait "$RUN_PID" || STATUS=$?
kill "$WATCHDOG" 2>/dev/null || true
kill "$STALLDOG" 2>/dev/null || true
ELAPSED=$(( SECONDS - START ))

print "\ndispatch: exit $STATUS after ${ELAPSED}s"
if (( ELAPSED >= TIMEOUT )); then
  print -u2 "dispatch: TIMED OUT — killed at ${TIMEOUT}s. Treat as a non-converging round."
fi

print "\n--- last 40 lines of $LOG ---"
tail -40 "$LOG"

# A sandbox auto-reject is TERMINAL -- the model does not recover from it, and
# the run ends wherever it happened. Two rounds have been lost to one: #0097
# round 3 and #0124 round 2, both to a mistyped absolute path that fell outside
# the worktree. `opencode run` still exits 0, so without this the harness
# reports a successful round.
# `grep -c` prints 0 AND exits 1 on no match, so `|| print 0` appended a second
# zero and `(( REJECTS > 0 ))` choked on "00" -- an error on every clean round.
REJECTS=$(grep -ac 'auto-rejecting' "$LOG" 2>/dev/null)
REJECTS=${REJECTS:-0}
if (( REJECTS > 0 )); then
  print -u2 "\ndispatch: $REJECTS SANDBOX AUTO-REJECT(S) in this round -- the run was cut short there."
  print -u2 "dispatch: the rejected path is on the line above each; check it for a typo before"
  print -u2 "dispatch: blaming the model. An absolute path outside the worktree is the usual cause."
  grep -a -B1 'auto-rejecting' "$LOG" | tail -6 | sed 's/^/  /' >&2
fi

print "\n--- working tree after round $ROUND (base $BASE_SHA) ---"
if [[ -z "$(git status --porcelain)" ]]; then
  print "NO CHANGES. The run produced nothing — count it as a failed round, do not re-dispatch unchanged."
  exit 7
fi

# Ground truth for the suite, recorded next to whatever the round claimed.
#
# Two rounds have now closed by asserting a passing test count they never
# measured -- #0013 round 2 invented "216 + 4 new + 15 existing = 235", and
# #0119 round 1 wrote "all 261 tests pass, zero failures" while four failed.
# The reviewer catches it by re-running, but that is one round late. Printing
# the real line into the round's own log puts the claim and the fact in the
# same artifact.
if [[ -d YardKit ]]; then
  print "\n--- swift test, run by the harness (not by the model) ---"
  ( cd YardKit && swift test 2>&1 ) > "$LOG_DIR/$ISSUE-round$ROUND-suite.txt" 2>&1 &
  SUITE_PID=$!
  ( sleep 300; kill -KILL "$SUITE_PID" 2>/dev/null ) &
  SUITE_DOG=$!
  wait "$SUITE_PID" 2>/dev/null || true
  kill "$SUITE_DOG" 2>/dev/null || true
  SUITE_LINE=$(grep -E 'Test run with [0-9]+ tests' "$LOG_DIR/$ISSUE-round$ROUND-suite.txt" | tail -1 || true)
  if [[ -n "$SUITE_LINE" ]]; then
    print -r -- "$SUITE_LINE"
  else
    print "NO 'Test run with N tests' LINE. The suite did not build, or a test is blocking."
    print "First error:"
    grep -m1 -E '^/.*error:' "$LOG_DIR/$ISSUE-round$ROUND-suite.txt" || print "  (none found — see $LOG_DIR/$ISSUE-round$ROUND-suite.txt)"
  fi
fi
git status --short
print ""
git diff --stat
