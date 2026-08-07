#!/usr/bin/env zsh
#
# preflight-issue.sh NNNN [--quiet]
#
# Checks an issue against the mechanical entries in docs/review-failures.md
# before it is dispatched. Every check here exists because a round was already
# lost to the thing it looks for — see the failure log for which.
#
# Exit 0  all hard checks pass (warnings may still print)
# Exit 9  a hard check failed; fix the issue text before dispatching
#
# dispatch-issue.sh runs this and refuses to dispatch on exit 9. Run it by hand
# while authoring, when there is still time to fix the issue cheaply.
#
# Every grep pipeline here ends in `|| true`. This script runs under ERR_EXIT
# and PIPE_FAIL, and a grep that matches nothing exits 1 — which is the *common*
# path for most of these checks. A guard that kills the script on every healthy
# issue looks identical to one that works. See local-ai-workflow-log.md 3.6c.

set -u
setopt ERR_EXIT PIPE_FAIL

REPO_ROOT="${0:A:h:h}"
cd "$REPO_ROOT"

QUIET=0
ISSUE=""
while (( $# )); do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    *)       ISSUE="$1"; shift ;;
  esac
done

[[ -n "$ISSUE" ]] || { print -u2 "usage: preflight-issue.sh NNNN [--quiet]"; exit 1 }
FILE="issues/$ISSUE.md"
[[ -f "$FILE" ]] || { print -u2 "preflight: $FILE does not exist"; exit 1 }

# Checks run against the SPEC only — everything above the first `## Review`,
# `## Work log`, or `## Sequencing` heading. Those sections narrate what went
# wrong in a past round, and discussing a bad path there is correct prose, not a
# defect. Scanning them made this script reject #0085 for documenting its own
# post-mortem.
SPEC=$(mktemp -t preflight-spec)
trap 'rm -f "$SPEC"' EXIT
awk '/^## (Review|Work log|Sequencing)/{exit} {print}' "$FILE" > "$SPEC"

# Issues for a code module must meet stricter checks than a docs or decision
# issue, which legitimately names no source file and runs no test suite.
MODULE=$(awk -F'|' '/\*\*Module\*\*/ {gsub(/ /,"",$3); print $3; exit}' "$FILE" || true)
IS_CODE=0
case "$MODULE" in
  *YardKit*|*YardGit*|*yard*|*Switchyard*|*Broker*) IS_CODE=1 ;;
esac

FAILED=0
say()  { (( QUIET )) || print "$@" }
pass() { say "  PASS  $1" }
warn() { say "  WARN  $1"; say "        $2" }
fail() { print -u2 "  FAIL  $1"; print -u2 "        $2"; FAILED=1 }

say "preflight $FILE  (module: ${MODULE:-none}, code: $IS_CODE)"

# --- Check 1 (HARD) — a file inside an executable target --------------------
# SwiftPM cannot '@testable import' an executable target, so nothing there can
# be unit-tested. #0085 spent a round discovering this about its own spec.
if [[ -f YardKit/Package.swift ]]; then
  EXEC_DIRS=(${(f)"$(sed -n '/\.executableTarget(/,/)/p' YardKit/Package.swift \
    | sed -n 's/.*path: "\([^"]*\)".*/\1/p' || true)"})
  BAD_EXEC=""
  for d in $EXEC_DIRS; do
    [[ -n "$d" ]] || continue
    # main.swift is legitimately there — it is the entry point, not a tested unit.
    hits=$(grep -oE "YardKit/$d/[A-Za-z0-9_]+\.swift" "$SPEC" \
      | grep -v '/main\.swift$' | sort -u || true)
    [[ -z "$hits" ]] || BAD_EXEC+="$hits"$'\n'
  done
  if [[ -n "${BAD_EXEC//[[:space:]]/}" ]]; then
    fail "names a file inside an executable target" \
"${BAD_EXEC}Move it to a library target (Sources/YardKit or Sources/YardGit).
Nothing in an executable target can be unit-tested. See review-failures #0085."
  else
    pass "no file named inside an executable target"
  fi
fi

# --- Check 2 (HARD) — scratch paths outside the worktree --------------------
# OpenCode auto-rejects external_directory writes. Two rounds died on this
# (#0070 r2, #0098 r1), both producing nothing. A line that *warns* about those
# paths is fine; a line that directs work there is not.
OUTSIDE=$(grep -nE '(^|[^A-Za-z0-9_/])((/private)?/(var/)?tmp/|\$TMPDIR)' "$SPEC" \
  | grep -viE 'reject|cannot|never|not |outside|denie|denied|fail|instead of' || true)
if [[ -n "$OUTSIDE" ]]; then
  fail "directs work to a path outside the worktree" \
"$OUTSIDE
The sandbox auto-rejects writes there and the round produces nothing. Use a
build/-relative path. See review-failures #0098 and AGENTS.md Rule 6."
else
  pass "no scratch path outside the worktree"
fi

# --- Check 3 — names a concrete source file ---------------------------------
# The strongest signal in the whole failure log: every code round that failed
# named zero source paths; every one that converged in a single round named
# exactly one. Hard for code modules, advisory elsewhere.
NAMED=$(grep -oE '(YardKit/)?(Sources|Tests)/[A-Za-z0-9_/]+\.swift' "$SPEC" \
  | grep -v '/main\.swift$' | sort -u || true)
if [[ -n "$NAMED" ]]; then
  pass "names $(print -r -- "$NAMED" | grep -c . || true) source file(s)"
elif (( IS_CODE )); then
  fail "names no source file to create or edit" \
"Every code round that failed named zero paths; every one that converged named
exactly one. Name the file. See issues/Issues.md, 'Sizing an issue for delegation'."
else
  warn "names no source file" \
"Fine for a docs or decision issue. Otherwise name the file."
fi

# --- Check 4 (HARD for code) — names a verification command -----------------
# Without one, a round cannot be graded and 'the model said it passed' is the
# only evidence. #0011 r1 was accepted and later rejected for exactly this.
if (( IS_CODE )); then
  if grep -qE 'swift test|xcodebuild [^|]*test|Test run with' "$SPEC"; then
    # A count with no baseline is not evidence. A round once added eight
    # XCTest cases to a swift-testing package: the reported count was
    # identical with the new file deleted, and the criterion still "passed".
    if grep -qiE 'greater than|more than|must (be )?(exceed|increase)|higher than' "$SPEC"; then
      pass "names a verification command with a baseline count"
    else
      warn "names a verification command but no baseline count" \
"State what N must exceed, e.g. \"N must be greater than 83, the count on main
before this change\". Without it, tests that never join the run still pass the
criterion. See review-failures #0086 r1."
    fi
  else
    fail "names no verification command" \
"State the exact command and the exact line its output must contain, e.g.
\"swift test prints a 'Test run with N tests' line you paste\". Otherwise the
round cannot be graded. See review-failures #0011 r1."
  fi
fi

# --- Check 5 (HARD) — a referenced branch must be present in this tree ------
# #0090 round 1 was told to "start from issue/0011", but its worktree was cut
# from main, which does not contain that branch's Envelope.swift. A one-field
# type change became a from-scratch reimplementation, and was rejected.
BRANCH_REFS=$(grep -oE 'issue/[0-9]{4}' "$SPEC" | sort -u || true)
BAD_BASE=""
for dep in ${(f)BRANCH_REFS}; do
  [[ -n "$dep" ]] || continue
  [[ "$dep" == "issue/$ISSUE" ]] && continue
  # A line telling the model NOT to start from a branch is guidance, not a base
  # requirement — the fix applied to #0091 reads exactly that way.
  grep -n "$dep" "$SPEC" | grep -qiE 'do not|don.t|never|not start|rather than|instead of' && continue
  git rev-parse --verify -q "$dep" >/dev/null 2>&1 || continue
  git merge-base --is-ancestor "$dep" HEAD 2>/dev/null || BAD_BASE+="$dep "
done
if [[ -n "$BAD_BASE" ]]; then
  fail "depends on a branch that is not in this tree: $BAD_BASE" \
"The issue tells the implementer to build on that branch, but it is not an
ancestor of HEAD, so none of its files are present. Either cut this branch from
that one, or rewrite the issue to not depend on it. See review-failures #0090."
else
  pass "no dependency on an absent branch"
fi

# --- Check 6 (WARN) — asks the implementer to discover rather than apply ----
# Verification is the reviewer's job; the implementer applies conclusions.
# Open-ended discovery is what killed #0070 r2 — the review feedback itself
# made the round unrunnable.
VERIFY=$(grep -nE "rather than trusting|run .?-h.? |check (the )?current usage|verify (the )?current|verify (how|where|whether)|confirm whether|determine whether|find out (what|whether)" "$SPEC" || true)
if [[ -n "$VERIFY" ]]; then
  warn "asks the implementer to discover a fact rather than stating it" \
"$VERIFY
Run it yourself and write the result into a '## Givens' block as fact.
A criterion checking the round's own output is fine; a research task is not."
else
  pass "states facts rather than delegating discovery"
fi

# --- Check 7 (WARN) — concurrency headroom ----------------------------------
# LM Studio is PARALLEL 2. A third dispatch queues silently and is
# indistinguishable from a very slow round.
RUNNING=$(pgrep -f 'opencode run' 2>/dev/null | grep -c . || true)
if (( RUNNING >= 2 )); then
  warn "$RUNNING dispatches already running (LM Studio is PARALLEL 2)" \
"A third would queue silently rather than run. Wait for a slot."
else
  pass "$RUNNING/2 dispatch slots in use"
fi

if (( FAILED )); then
  print -u2 "preflight: FAILED — fix $FILE, commit the planning update, then dispatch."
  exit 9
fi
say "preflight: ok"
exit 0
