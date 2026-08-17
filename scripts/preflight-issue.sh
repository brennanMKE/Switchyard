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
#
# That cut is positional, so a `## Review` heading placed ABOVE the `## Change`
# blocks silently truncates the spec to nothing and every content check below
# fails on an issue that would otherwise pass. #0028 round 2 hit exactly this:
# recording round 1's acceptance near the top turned checks 3 and 4 into FAILs
# ("names no source file", "no baseline count") on an issue that had just passed
# both. The failure is maximally confusing because it reports content defects,
# not a placement problem. Any two-round-by-design issue reaches this, so it is
# guarded rather than documented.
SPEC=$(mktemp -t preflight-spec)
trap 'rm -f "$SPEC"' EXIT
awk '/^## (Review|Work log|Sequencing)/{exit} {print}' "$FILE" > "$SPEC"

CUT_AT=$(grep -n '^## \(Review\|Work log\|Sequencing\)' "$FILE" | head -1 | cut -d: -f1 || true)
LAST_CHANGE=$(grep -n '^## Change' "$FILE" | tail -1 | cut -d: -f1 || true)
if [[ -n "$CUT_AT" && -n "$LAST_CHANGE" ]] && (( CUT_AT < LAST_CHANGE )); then
  print -u2 "preflight: FAIL — a '## Review'/'## Work log'/'## Sequencing' heading at line $CUT_AT"
  print -u2 "         sits ABOVE the last '## Change' block at line $LAST_CHANGE, so the spec is"
  print -u2 "         truncated and every content check below would fail spuriously."
  print -u2 "         Move those sections to the END of the issue and re-run."
  exit 1
fi

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
  # Match against whitespace-FLATTENED text, the way check 4b already does. The
  # first version grepped the raw file, so an issue that wrapped "greater\nthan"
  # across a line break -- which prose at this width does constantly -- read as
  # having no baseline at all. #0189 was written WITH a baseline, warned anyway,
  # and the warning was accurate about nothing. Same class as the staleness
  # check that suppressed its own stderr: a guard defeated by formatting is
  # indistinguishable from a guard with nothing to report.
  SPEC_FLAT=$(tr -s '[:space:]' ' ' < "$SPEC")
  if print -r -- "$SPEC_FLAT" | grep -qE 'swift test|xcodebuild [^|]*test|Test run with'; then
    # A count with no baseline is not evidence. A round once added eight
    # XCTest cases to a swift-testing package: the reported count was
    # identical with the new file deleted, and the criterion still "passed".
    if print -r -- "$SPEC_FLAT" | grep -qiE 'greater than|more than|must (be )?(exceed|increase)|higher than'; then
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

# --- Check 6b (HARD) — the issue must be claimed before work starts --------
# The tracker is what a human reads to know what is being worked on. Issues
# were going straight from open to resolved, so a dispatch that was actively
# running showed as untouched. Gate it here rather than trusting anyone to
# remember.
STATUS=$(grep -m1 '^| \*\*Status\*\*' "$FILE" | awk -F'|' '{gsub(/ /,"",$3); print $3}' || true)
if [[ "$STATUS" == "in-progress" ]]; then
  pass "issue is claimed (in-progress)"
else
  fail "issue status is '$STATUS', not 'in-progress'" \
"Claim it before dispatching:  ./scripts/set-issue-status.sh $ISSUE in-progress
An issue being actively worked must say so, or the tracker lies about what is
happening. Set it back to 'open' if the round is abandoned."
fi

# --- Check 3b (HARD) — the Module field must not be empty -------------------
# An empty Module makes this script classify the issue as non-code, which skips
# Check 4 -- the hard "names a verification command with a baseline count".
# Seven issues filed through new-issue.sh sat that way, each one reading as
# clean while the check that matters most was never run.
MODULE_RAW=$(grep -m1 '^| \*\*Module\*\*' "issues/$ISSUE.md" 2>/dev/null \
  | sed 's/^| \*\*Module\*\* | *//; s/ *|$//' || true)
if [[ -z "${MODULE_RAW// /}" ]]; then
  fail "the Module field is empty" \
"An empty Module classifies this as a non-code issue and SKIPS the verification
check. Fill it in -- YardGit, YardKit, yard, app, docs, or a combination."
else
  pass "Module is set ($MODULE_RAW)"
fi

# --- Check 4b (HARD) — the stated baseline matches main's real count --------
# #0096 round 1 was reviewed against a baseline of 216 when main was 225. A
# stale number hides a small increase, and can make an unmoved count read as
# progress. docs/test-baseline.txt is rewritten whenever main's suite is run.
#
# Escalated from a warning to a hard failure after #0137 round 1. A stale
# absolute does not merely fail to help -- it actively misleads. That round
# measured the correct 488, compared it against the issue's stale 453, decided
# its own measurement was wrong, and spent the back half of the round chasing a
# phantom "caching issue", including an `rm -rf ~/.cache/org.swift.swiftpm`
# that the sandbox correctly rejected. The issue text even said "trust the
# delta, not the absolute", and the model trusted the absolute anyway. On a
# project that merges a dozen times a day, refreshing the number costs one
# edit; not refreshing it cost eight tool calls and a rejected command.
if [[ -f docs/test-baseline.txt ]]; then
  REAL=$(<docs/test-baseline.txt)
  # $SPEC is a FILE holding the spec text, not the text itself.
  # The phrase often wraps across a line break in the issue text, so flatten
  # whitespace before matching -- the first version missed every wrapped one
  # and printed nothing, which read as "no baseline stated".
  #
  # The first extractor matched only the literal phrase "reported N on", so it
  # was silent for every issue that phrased its baseline any other way -- which
  # is how #0137 reached dispatch carrying a stale 453. Escalating that check to
  # hard would have changed nothing, because it never fired. It now collects
  # EVERY plausible baseline number in the spec and fails if any disagrees with
  # main, because a stale absolute anywhere in the text is what the model reads.
  FLAT=$(tr '\n' ' ' < "$SPEC")
  # Only numbers presented as the CURRENT baseline count. An expected *result*
  # ("the result here is 486") legitimately differs from main and must not be
  # flagged -- the first widened version failed two issues for exactly that,
  # because it treated every suite-sized number as a claim about main.
  #
  # Anchors, all meaning "what main is right now":
  #   docs/test-baseline.txt read/reads N
  #   main is N  /  main's suite is N  /  main reported N
  STATED=$(print -r -- "$FLAT" \
    | grep -oE '(test-baseline\.txt[^0-9]{0,30}|main([^0-9.]{0,20}(is|reported|suite is))[^0-9]{0,10})\*{0,2}[0-9]{2,4}' \
    | grep -oE '[0-9]{2,4}$' | sort -u || true)
  STALE=""
  for n in ${(f)STATED}; do
    (( n >= 100 && n <= 9999 )) || continue
    [[ "$n" == "$REAL" ]] || STALE+="$n "
  done
  if [[ -n "${STALE// /}" && -n "$REAL" ]]; then
    fail "issue states main's suite is ${STALE% }, but it is $REAL" \
"Refresh the number in $FILE before dispatching. A stale absolute sends the
round chasing a phantom -- #0137 round 1 lost eight tool calls to exactly this,
deciding its own correct measurement must be wrong."
  elif [[ -n "$STATED" ]]; then
    pass "every stated suite count matches main ($REAL)"
  fi
fi

# --- Check 7 (HARD) — the primary checkout is on main ------------------------
# Replaced the LM Studio slot checks on 2026-08-16, when implementation moved
# from a local model to Sonnet subagents and `lms`/`opencode run` stopped
# existing in this workflow. Those checks asked whether the host had capacity;
# this one asks the question that actually cost us something.
#
# On 2026-08-12 a round was run IN THE PRIMARY CHECKOUT. Its output landed as
# uncommitted changes on `main`, on no branch anywhere, and the twelve hand-made
# commits around it forced the 2026-08-16 reset of `main` to 3c49ba6. See
# docs/workflow-reset-2026-08-16.md.
#
# The primary checkout stays on `main` permanently: it is where merges happen and
# what a human watches. A round belongs in ../switchyard-NNNN. If the primary is
# on an issue branch, something has already gone wrong -- either a round is about
# to run here, or one already did.
PRIMARY=$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')
if [[ -n "$PRIMARY" ]]; then
  PRIMARY_BRANCH=$(git -C "$PRIMARY" symbolic-ref --quiet --short HEAD 2>/dev/null || print detached)
  if [[ "$PRIMARY_BRANCH" != main ]]; then
    fail "the primary checkout is on '$PRIMARY_BRANCH', not main" \
"$PRIMARY must stay on main permanently -- it is where merges land and what a
human watches. A round runs in ../switchyard-$ISSUE, never here.

  git -C $PRIMARY switch main

If a round has already run in the primary checkout, salvage its work to a branch
before switching: docs/workflow-reset-2026-08-16.md is what happens otherwise."
  else
    pass "primary checkout is on main"
  fi
fi

# --- Check 10 (WARN) — the issue is not oversized ---------------------------
# #0017 round 1 produced nothing because its mandated reading set (issue +
# Issues.md + AGENTS.md + the skill = 106KB) exceeded a 65k context. Sonnet's
# context makes that specific arithmetic irrelevant, and the check was rewritten
# rather than deleted, because the underlying signal was never really about
# tokens: an issue that large is an issue with more than one deliverable in it.
#
# Advisory, and generous. Bytes/4 is the usual rough token estimate.
ISSUE_TOK=$(( $(wc -c < "$FILE") / 4 ))
if (( ISSUE_TOK > 25000 )); then
  warn "issue is ~${ISSUE_TOK} tokens — that is a sizing smell, not a context problem" \
"Sonnet can hold it. The concern is that no issue this large has one deliverable:
every oversized issue in the failure log (#0010, #0011, #0012) failed by getting
partway into each of several pieces. Consider splitting it."
else
  pass "issue size ~${ISSUE_TOK} tokens"
fi

# A `grep -c '<pattern>'` criterion whose expected count was written from memory
# rather than measured. #0170 specified 1 for a string appearing twice (doc
# comment plus call site); #0151 did the identical thing with GIT_INDEX_FILE.
# Both were harmless because review caught them, but a presence criterion is a
# gate — a wrong one either passes a defect or fails a correct round.
#
# ADVISORY, not hard: the count is compared against the issue's own pasted
# fenced blocks, which is the right denominator only when the issue pastes the
# whole file. When it pastes a region, a mismatch is expected and fine.
PRESENCE_WARN=()
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  pat=${line#*grep -c }
  pat=${pat#[\'\"]}
  quote=${line#*grep -c }
  quote=${quote[1]}
  pat=${pat%%${quote}*}
  [[ -n "$pat" ]] || continue
  # The expected count: the last small integer on the line.
  want=$(print -r -- "$line" | grep -oE '[0-9]+' | tail -1 || true)
  [[ "$want" == <-> ]] || continue
  (( want <= 5 )) || continue
  got=$(awk '/^```/{f=!f; next} f' "$SPEC" | grep -cF -- "$pat" || true)
  [[ "$got" == "$want" ]] || PRESENCE_WARN+=("$pat  says $want, pasted blocks contain $got")
done < <(grep -E "grep -c ['\"][^'\"]+['\"].*[0-9]" "$SPEC" || true)
if (( ${#PRESENCE_WARN} )); then
  warn "a grep -c criterion may not match the pasted block" \
"${(F)PRESENCE_WARN}
Run the grep against the pasted block and use its real count. Expected only when
the issue pastes a region rather than a whole file. #0170 and #0151 both shipped
a criterion that could not be satisfied as written."
else
  pass "grep -c criteria agree with the pasted blocks"
fi

# A pasted `@Test func` name that ALREADY EXISTS in the test module will not
# compile: top-level test function names share the module namespace. The issue
# has been advising planners of this in prose all night; #0043 proves prose is
# not enough. It was planned against a scratch copy of an older `main`, #0042
# landed two colliding names while it waited, and its pasted block could not
# have compiled as written. The round renamed both correctly — but the issue's
# own Expected behavior ("all eleven test functions named as pasted") was
# unsatisfiable, and three mutation rows named a now-ambiguous test.
#
# This is mechanical, so it is a check rather than a lesson.
CLASH=()
for name in ${(f)"$(grep -oE '@Test[[:space:]]+func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$SPEC" 2>/dev/null | awk '{print $NF}' | sort -u)"}; do
  [[ -n "$name" ]] || continue
  # Present in the tree already, and NOT in a file this issue says it creates?
  EXISTING=$(grep -rlE "@Test[[:space:]]+func[[:space:]]+${name}\\b" YardKit/Tests 2>/dev/null || true)
  [[ -n "$EXISTING" ]] || continue
  # If the issue names that same file as its own deliverable, it is a rewrite,
  # not a clash.
  OWN=0
  # An array, not a string subscript: `${${(f)VAR}[1]}` indexes the first
  # CHARACTER, so the clash message printed a bare "Y" instead of the path.
  typeset -a HITS
  HITS=(${(f)EXISTING})
  for f in $HITS; do
    grep -qF "$f" "$SPEC" && OWN=1
  done
  (( OWN )) || CLASH+=("$name -> $HITS[1]")
done
if (( ${#CLASH} )); then
  fail "pastes @Test name(s) that already exist in YardKit/Tests" \
"Top-level @Test function names share the module namespace, so the pasted block
will not compile:

  ${(F)CLASH}

Rename in the issue before dispatching. #0043 hit this when a concurrent issue
landed colliding names after its planning scratch was taken."
else
  pass "no pasted @Test name collides with the test module"
fi

if (( FAILED )); then
  print -u2 "preflight: FAILED — fix $FILE, commit the planning update, then dispatch."
  exit 9
fi

say "preflight: ok"
exit 0
