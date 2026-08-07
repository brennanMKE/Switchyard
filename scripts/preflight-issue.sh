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

# Checks run against the SPEC only — everything above the first `## Review` or
# `## Work log` heading. Those trailing sections narrate what went wrong in a
# past round, and discussing a bad path there is correct prose, not a defect.
# Scanning them made this script fail #0085 for quoting the very mistake its
# review section exists to record.
SPEC=$(mktemp -t preflight-spec)
trap 'rm -f "$SPEC"' EXIT
awk '/^## (Review|Work log)/{exit} {print}' "$FILE" > "$SPEC"

FAILED=0
say()  { (( QUIET )) || print "$@" }
pass() { say "  PASS  $1" }
warn() { say "  WARN  $1"; say "        $2" }
fail() { print -u2 "  FAIL  $1"; print -u2 "        $2"; FAILED=1 }

say "preflight $FILE"

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
# OpenCode auto-rejects external_directory writes. Two rounds died on this.
# A line that *warns* about those paths is fine; a line that directs work there
# is not, so lines carrying a negation are treated as advisory.
OUTSIDE=$(grep -nE '(^|[^A-Za-z0-9_/])/(private/)?(var/)?tmp/' "$SPEC" \
  | grep -viE 'reject|cannot|never|not |outside|denie|denied|fail|instead of' || true)
if [[ -n "$OUTSIDE" ]]; then
  fail "directs work to a path outside the worktree" \
"$OUTSIDE
The sandbox auto-rejects writes to /tmp and /var/tmp. Name a build/-relative
path instead. See review-failures #0098 and AGENTS.md Rule 6."
else
  pass "no scratch path outside the worktree"
fi

# --- Check 3 (WARN) — names a concrete file --------------------------------
# Every issue that converged named exactly one file; every issue that failed to
# converge named none. Docs- and decision-issues legitimately name none, so this
# warns rather than blocks.
NAMED=$(grep -coE '`[A-Za-z0-9_./-]+\.(swift|md|json|sh|plist|pbxproj)`' "$SPEC" || true)
if (( NAMED > 0 )); then
  pass "names $NAMED concrete file reference(s)"
else
  warn "names no concrete file" \
"Every converged issue named a file; every issue that did not converge named none.
If this is a decision or docs issue that is fine — otherwise name the file."
fi

# --- Check 4 (WARN) — asks the model to verify instead of stating ----------
# Open-ended verification is the shape the model handles worst; it turned #0070
# round 2 from implementation into research and the round died.
VERIFY=$(grep -nE "rather than trusting|run .?-h.? |check (the )?current usage|verify (the )?current|confirm whether|find out (what|whether)" "$SPEC" || true)
if [[ -n "$VERIFY" ]]; then
  warn "asks the model to verify a fact rather than stating it" \
"$VERIFY
Run it yourself and write the result into the issue as a given.
See review-failures #0070 r2 and checklist item 7."
else
  pass "states facts rather than delegating verification"
fi

if (( FAILED )); then
  print -u2 "preflight: FAILED — fix $FILE, commit the planning update, then dispatch."
  exit 9
fi
say "preflight: ok"
exit 0
