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
# Back to 1800 now that we dispatch ONE round at a time (2026-08-07). The 4200
# value existed to absorb the ~2.3x per-round penalty of 4-way contention; with
# no contention there is none to absorb, and a slack timeout is a real cost --
# at 4200 a genuinely hung round burns 70 minutes before the watchdog fires.
# If the dispatch ceiling ever goes back above 1, raise this WITH it.
TIMEOUT=1800
# Kill a round that has written nothing to its log for this long. A working
# round appends constantly; silence this long means a hung request.
#
# Back to 420 alongside TIMEOUT, for the same reason: the 900 value covered the
# 239s silent prefill of the LAST of four concurrent rounds. A solo round's
# prefill is 107.7s, so 420 restores the original ~4x margin.
# COUPLED: await-dispatch.sh's QUIET_LIMIT must stay above this.
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
  # The overwhelmingly common cause is invoking this script by the WRONG PATH.
  # `REPO_ROOT="${0:A:h:h}"` then `cd "$REPO_ROOT"` means the script operates on
  # whichever checkout it was launched from — so `./scripts/dispatch-issue.sh`
  # run from the primary checkout dispatches against `main` and dies here, with
  # a message about branches that says nothing about the actual mistake.
  # The issue's own worktree usually exists and is already on the right branch.
  WT="${REPO_ROOT:h}/switchyard-$ISSUE"
  if [[ "$CURRENT" == "main" && -d "$WT" ]]; then
    die "invoked from the primary checkout, which is on 'main'.
This script operates on the checkout it was launched from, so it would dispatch
against main. #$ISSUE already has a worktree — invoke it by that path instead:

  $WT/scripts/dispatch-issue.sh $ISSUE --round N

The primary checkout stays on main permanently; never switch it to an issue
branch and never run a dispatch in it." 8
  fi
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
    # The ornith branch above probes LM Studio before dispatching; this branch
    # had no equivalent, and the asymmetry cost #0129 round 1. OpenCode has no
    # anthropic provider configured on this machine and never has — `opencode
    # models` lists lmstudio, nebius, openai and opencode only — so the round
    # died in one second with an opaque `UnknownError` from OpenCode's own
    # gateway rather than a 401. The sonnet path had never been exercised, so
    # the workflow table documented a capability that did not exist.
    opencode models 2>/dev/null | grep -qx "$MODEL" || die \
"opencode has no '$MODEL'.

'opencode auth list' shows the configured credentials; there is no anthropic
provider here, so --model sonnet cannot run. Either configure one, or dispatch
this round to a provider that is available. Do not retry unchanged: the failure
is instant, total, and produces an UnknownError rather than an auth message." 6
    print "dispatch: NOTE -- this round is BILLED. Ornith is $0.00; Sonnet is not."
    ;;
  *)
    die "unknown --model '$MODEL_CHOICE'. Use ornith (local, default) or sonnet (billed)." 2
    ;;
esac
LOG_DIR=".switchyard-runs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$ISSUE-round$ROUND.log"
DONE="$LOG_DIR/$ISSUE-round$ROUND.done"
BASE_SHA=$(git rev-parse HEAD)

# A positive completion record, written on EVERY exit path.
#
# Without it, "is this round finished?" can only be inferred from outside —
# by a process pattern (which a backgrounded wrapper keeps alive in its argv
# forever) or by log staleness (a threshold, so a genuinely slow round can be
# misjudged). Both are guesses, and they degrade exactly when something has
# gone wrong, which is when the answer matters most. Two dispatchers were
# stranded for over an hour each on 2026-08-07 by the first; the second is a
# heuristic that replaced it.
#
# This file's existence IS the answer.
#
# Every round's record for this issue is cleared at start, not just this one's.
# The first version removed only "$DONE", so round 1's record survived into
# round 2 -- and `await-dispatch.sh` globs `NNNN-round*.done`, matched the stale
# one, and reported "no dispatch running" twice while round 2 was demonstrably
# live. A dispatcher following it would have reviewed an empty tree and called
# the round failed. At most one record per issue exists at any time, and it
# always describes the latest round.
# The (N) qualifier is load-bearing: this script runs under ERR_EXIT, and a
# zsh glob that matches nothing is a fatal error, not an empty list. Round 1
# never has a prior record, so without (N) this line killed every first
# dispatch. Caught by a control, one edit after being written.
rm -f $LOG_DIR/$ISSUE-round*.done(N)

STATUS=0
ELAPSED=0
SUITE_LINE=""
REJECTS=0
write_done() {
  local code=$1
  # `git status` can fail here (a mid-flight index lock); a completion record
  # that throws is worse than one with an empty field.
  #
  # CHANGED_COUNT is captured *before* the round commit stages anything. The
  # first version counted here, after staging, so it read 0 on every successful
  # round -- and 0 was the no-changes signal, which is exactly the wrong thing
  # to say about a round that worked.
  local changed
  if [[ -n "${CHANGED_COUNT:-}" ]]; then
    changed="$CHANGED_COUNT"
  else
    changed=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ') || changed=""
  fi
  {
    print -r -- "{"
    print -r -- "  \"issue\": \"$ISSUE\","
    print -r -- "  \"round\": $ROUND,"
    print -r -- "  \"exit\": $code,"
    print -r -- "  \"elapsedSeconds\": ${ELAPSED:-0},"
    print -r -- "  \"timedOut\": $( (( ${ELAPSED:-0} >= TIMEOUT )) && print true || print false ),"
    print -r -- "  \"sandboxRejects\": ${REJECTS:-0},"
    print -r -- "  \"changedPaths\": ${changed:-0},"
    print -r -- "  \"baseSha\": \"$BASE_SHA\","
    print -r -- "  \"model\": \"${MODEL:-unknown}\","
    print -r -- "  \"roundCommit\": \"${COMMIT_SHA:-}\","
    print -r -- "  \"suiteLine\": \"${SUITE_LINE//\"/\\\"}\""
    print -r -- "}"
  } > "$DONE"
}
trap 'write_done $?' EXIT

read -r -d '' PROMPT <<EOF || true
Work issue $ISSUE. Read issues/$ISSUE.md. That is the only document you need.

Do NOT read AGENTS.md -- it is already in your context, and re-reading it costs
~5k tokens for nothing. Do NOT read issues/Issues.md; it is the tracker's process
guide for humans and reviewers, ~10k tokens of which none is your job this round.
#0017 round 1 died because these two reads plus the skill filled the context
before a line was written, and it compacted away the issue's own source block.

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
  8b. Load the \`swift-guidance\` skill before writing Swift ONLY IF the issue
     does not already contain the Swift source to write. When the issue carries
     a verbatim source block, it was authored with that skill loaded and the
     code already conforms -- loading it again costs ~4k tokens and teaches you
     nothing the block does not already show. When you do load it, follow its
     stopping rule: it is guidance for writing the code, not an invitation to
     audit the repository.
  9. Read the files the issue names, then START EDITING. Do not survey the
     repository first. One round read twelve files without writing a line,
     filled its context to 49k, was compacted, and died -- it had treated a
     fully-specified issue as a research task. If you find yourself reading a
     file the issue did not name, stop and ask whether you already have what
     you need.

Finish by writing your report to \`$LOG_DIR/$ISSUE-round$ROUND.report.md\`:
what you changed, what you ran, what it printed, and anything you could not do.
Write it with a heredoc (\`cat > path <<'MD' ... MD\`). Its first line becomes
the subject of this round's commit, so make that line a single plain sentence
saying what the round did. The harness makes the commit; you must still not run
git yourself.

Then say the same thing briefly in your final message.
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
# `grep -c` exits 1 on no match, and this script runs under ERR_EXIT -- so a
# CLEAN round killed the harness here, before the suite section, and no
# *-suite.txt was written. The `|| true` is what makes it safe; `${:-0}` alone
# was not, which is the second bug in this three-line guard.
REJECTS=$(grep -ac 'auto-rejecting' "$LOG" 2>/dev/null || true)
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
    # A round that applies its own mutations and forgets to restore one leaves
    # the tree red, and the line above still reads as a real measurement
    # because it names a plausible test count. #0019 round 2 finished with
    # mutation 2 still applied and reported "356 tests ... failed with 6
    # issues"; nothing shouted, and it was caught only by a human reading the
    # words. Say it loudly instead.
    if [[ "$SUITE_LINE" == *failed* ]]; then
      print ""
      print "*** THE SUITE IS RED AT THE END OF THIS ROUND. ***"
      print "Most often this is a mutation the round applied and did not restore."
      print "Check 'git diff' below before reading anything the round claimed:"
      git diff --stat -- YardKit/Sources/ || true
      print ""
    fi
  else
    print "NO 'Test run with N tests' LINE. The suite did not build, or a test is blocking."
    print "First error:"
    grep -m1 -E '^/.*error:' "$LOG_DIR/$ISSUE-round$ROUND-suite.txt" || print "  (none found — see $LOG_DIR/$ISSUE-round$ROUND-suite.txt)"
  fi
fi
git status --short
print ""
git diff --stat

# --- The round commit -------------------------------------------------------
#
# One commit per round on the issue branch, made by the harness rather than by
# the model. Decided by Brennan 2026-08-07.
#
# Why the harness and not the model: a commit is the clearest possible "this
# round is done", and squash-merging to `main` records no ancestry, so the
# branch is the only surviving account of how the work went. But letting the
# model run git re-opens the hole `AGENTS.md` Rule 4 exists to close — #0011
# round 1c edited CLAUDE.md mid-round, and a `git add -A` would sweep a round's
# own scratch files (#0023's mutation run left two behind). Staging here, by
# explicit path, makes the scope guarantee structural instead of a rule the
# model has to remember.
#
# The message body is the model's own words: it is asked to write
# `<LOG_DIR>/NNNN-roundN.report.md`, and the last 40 log lines stand in when it
# does not. A round that produced nothing never reaches here — that path exits 7
# above, and its emptiness stays a loud failure rather than becoming a commit.
REPORT="$LOG_DIR/$ISSUE-round$ROUND.report.md"
COMMIT_SHA=""
CHANGED_COUNT=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
{
  # Stage exactly what git says changed, by path, never -A. -z because a path
  # can contain anything, and this project counts NUL-terminated fields
  # everywhere else for the same reason.
  #
  # `git ls-files`, not `git status --porcelain`: porcelain prefixes each entry
  # with a status code that has to be stripped, and the obvious way to strip it
  # -- `sed -z` -- does not exist in BSD sed, which is what this Mac has. The
  # first version of this block used it, staged nothing, and made no commit
  # while still exiting 0. `ls-files` emits bare NUL-separated paths, so there
  # is nothing to strip and nothing to get wrong.
  typeset -a CHANGED
  CHANGED=("${(0)$(git ls-files -z --modified --others --deleted --exclude-standard)}")
  CHANGED=(${CHANGED:#})
  if (( ${#CHANGED} )); then
    git add -- "${CHANGED[@]}" 2>/dev/null || true
  fi
  if git diff --cached --quiet 2>/dev/null; then
    print "dispatch: nothing staged — no round commit made."
  else
    SUMMARY="#$ISSUE round $ROUND"
    if [[ -f "$REPORT" ]]; then
      # Normalise the subject here rather than asking the model to remember.
      #
      # AGENTS.md Rule 4b asks for an imperative line under 60 characters with
      # no trailing period. Three consecutive rounds ignored some part of that,
      # the third even with a worked example directly above the rule. It is
      # mechanically checkable, so the harness does it: prose lost three times.
      FIRST=$(grep -m1 -v '^[[:space:]]*$' "$REPORT" | sed 's/^#\{1,6\} *//')
      SUBJ_FIXED=0
      # A trailing period reads wrong in a subject line.
      if [[ "$FIRST" == *. ]]; then FIRST="${FIRST%.}"; SUBJ_FIXED=1; fi
      if (( ${#FIRST} > 60 )); then
        # Prefer cutting at a comma: "Add X and tests for A, B, C" becomes
        # "Add X and tests for A", which is a real subject rather than a
        # sentence with its tail sawn off.
        if [[ "$FIRST" == *,* ]]; then
          HEAD_PART="${FIRST%%,*}"
          (( ${#HEAD_PART} >= 20 && ${#HEAD_PART} <= 60 )) && FIRST="$HEAD_PART"
        fi
      fi
      if (( ${#FIRST} > 60 )); then
        FIRST="${FIRST[1,60]}"
        FIRST="${FIRST% *}…"
        SUBJ_FIXED=1
      fi
      (( SUBJ_FIXED )) && print -u2 \
"dispatch: NOTE -- the report's first line was not a usable commit subject and
dispatch: was normalised. AGENTS.md Rule 4b: imperative, under 60 characters,
dispatch: no trailing period. The body is where detail belongs."
      [[ -n "$FIRST" ]] && SUMMARY="#$ISSUE round $ROUND: $FIRST"
    fi
    {
      print -r -- "$SUMMARY"
      print -r -- ""
      if [[ -f "$REPORT" ]]; then
        cat "$REPORT"
      else
        # #0137 round 1 wrote its report to 0136-round1.report.md -- the wrong
        # issue number -- so the harness silently fell back to the log tail and
        # the commit got a generic subject. Say when that has probably happened.
        STRAYS=( $LOG_DIR/*-round$ROUND.report.md(N) )
        if (( ${#STRAYS} )); then
          print -u2 "dispatch: NOTE -- $REPORT is missing, but these exist:"
          print -u2 "  ${STRAYS[@]}"
          print -u2 "dispatch: a mis-numbered report is the likely cause; the commit"
          print -u2 "dispatch: subject fell back to the generic form."
        fi
        print -r -- "The round wrote no $REPORT. Last 40 lines of its log:"
        print -r -- ""
        tail -40 "$LOG" | sed 's/^/    /'
      fi
      print -r -- ""
      print -r -- "Round commit made by scripts/dispatch-issue.sh, not by the model."
      print -r -- "The body above is the model's own account of the round and is"
      print -r -- "NOT verified. #0137 round 1's report claimed files it never"
      print -r -- "touched and a layer it never created, while its actual diff was"
      print -r -- "correct -- read the diff, not the narrative."
      print -r -- "Not reviewed. Suite: ${SUITE_LINE:-not captured}"
    } | git commit -q -F - 2>/dev/null && COMMIT_SHA=$(git rev-parse --short HEAD)
    if [[ -n "$COMMIT_SHA" ]]; then
      print "\ndispatch: round committed as $COMMIT_SHA on $(git rev-parse --abbrev-ref HEAD)"
      print "dispatch: NOT reviewed and NOT merged — that is the reviewer's job."
    else
      print -u2 "\ndispatch: round commit FAILED; the work is staged but uncommitted."
    fi
  fi
} || true
