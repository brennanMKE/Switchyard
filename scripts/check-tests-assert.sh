#!/usr/bin/env zsh
#
# check-tests-assert.sh [path ...]
#
# Finds tests that cannot fail. Run it while REVIEWING a round, not before
# dispatching — it inspects produced code, not the issue.
#
# Two rounds have shipped green suites whose tests asserted nothing. Both hid a
# real defect, and one survived review because the test's name was read instead
# of its body. See docs/review-failures.md, AGENTS.md Rule 7.
#
# Reports, and exits 1 if anything is found:
#   INERT     a @Test function containing no assertion macro at all
#             (string literals are stripped before brace counting, so a
#              display name containing braces does not truncate the body)
#   NARROWING a loop over cases whose body discards all but one via
#             `guard case ... else { continue }`
#   TAUTOLOGY an assertion over literals, e.g. #expect(true)
#   ORPHANTEST a test file outside every declared target — never compiled
#   SKIPSHAPE a bare `return` in a @Test body — a quiet skip that reports success
#   HANDROLLED a hand-written `allCases`, which makes "every case" mean
#             "every case someone remembered"
#
# These are review prompts, not proof. Read every hit before acting on it —
# a test delegating to an `assert*` helper is a legitimate INERT false positive,
# and optional/Result unwrapping is a legitimate NARROWING one.

set -u
setopt PIPE_FAIL

TARGETS=("$@")
(( $#TARGETS )) || TARGETS=(YardKit/Tests)

FOUND=0

# --- INERT: brace-balanced scan of each @Test body -------------------------
INERT=$(find $TARGETS -name '*.swift' -type f 2>/dev/null | while read -r f; do
  awk '
    !intest && /@Test/ { intest=1; started=0; braces=0; body=""; name="?"; start=FNR }
    intest {
      if (name=="?" && match($0, /func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/))
        name = substr($0, RSTART+5, RLENGTH-5)
      body = body "\n" $0
      # Strip string literals before counting braces. A display name like
      # @Test("encodes via .map { $0 as Any } ?? NSNull()") balances its own
      # braces on the attribute line, which closed the body before the func
      # was ever reached and reported a real test as inert.
      l=$0; gsub(/"[^"]*"/, "", l)
      c=l; n=gsub(/\{/,"",c); c=l; m=gsub(/\}/,"",c); braces += n - m
      if (n>0) started=1
      if (started && braces<=0) {
        if (body !~ /#expect|#require|Issue\.record|withKnownIssue|XCTAssert|XCTFail|assert[A-Z]/)
          printf "  INERT      %s:%d  %s\n", FILENAME, start, name
        intest=0 } }
  ' "$f"
done || true)

# --- NARROWING: guard-case-continue inside a loop over cases ---------------
NARROW=$(grep -rn -A2 --include='*.swift' -E '^[[:space:]]*for +[A-Za-z_(].* in ' $TARGETS 2>/dev/null \
  | grep -B2 -E 'guard +case .*continue' \
  | grep -v '^--$' | sed 's/^/  NARROWING  /' || true)

# --- SKIPSHAPE: a bare `return` inside a @Test body -------------------------
# A bare `return` in a test is nearly always a quiet skip: the test exits
# before its assertions and reports success. Three rounds have now shipped
# this shape -- a guard-else-return in #0090, and in #0012 a test that merges
# an ancestor, gets "Already up to date", finds no MERGE_HEAD, and returns
# before its only #expect. The INERT scan cannot see it because an #expect is
# textually present.
#
# Bare `return` only: a closure returning a value uses `return x`, so this
# stays quiet on the common legitimate case.
SKIPSHAPE=$(find $TARGETS -name '*.swift' -type f 2>/dev/null | while read -r f; do
  awk -v FNAME="$f" '
    # A return preceded by Issue.record is a LOUD failure then exit — correct,
    # not a skip. Only an unannounced return is the defect.
    { prev2 = prev1; prev1 = cur; cur = $0 }
    /^[[:space:]]*return[[:space:]]*$/ || /else \{ return \}[[:space:]]*$/ {
      if (prev1 !~ /Issue\.record/ && prev2 !~ /Issue\.record/ && $0 !~ /Issue\.record/)
        printf "  SKIPSHAPE  %s:%d:%s\n", FNAME, FNR, $0
    }
  ' "$f"
done || true)

# --- TAUTOLOGY: an assertion whose operands are literals --------------------
# #expect(true) passes no matter what the code does. Found in a round that had
# already been graded "no inert tests" — the body does contain an assertion
# macro, so the INERT scan above cannot see it.
TAUT=$(grep -rn --include='*.swift' -E '#(expect|require)\((true|false|1 == 1|0 == 0)\)' $TARGETS 2>/dev/null \
  | sed 's/^/  TAUTOLOGY  /' || true)

# --- ORPHANTEST: a test file outside every declared target path ------------
# SwiftPM silently ignores a test file that is not under a declared target, so
# the suite stays green and the count does not move — and a round can report
# "216 tests passed" as proof of work while its tests were never compiled.
# #0095 lost a round to exactly this.
ORPHAN=""
if [[ -f YardKit/Package.swift ]]; then
  DECLARED=(${(f)"$(sed -n 's/.*path: \"\(Tests\/[A-Za-z0-9_]*\)\".*/\1/p' YardKit/Package.swift || true)"})
  if (( ${#DECLARED} )); then
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      rel="${f#YardKit/}"
      ok=0
      for d in $DECLARED; do
        [[ "$rel" == "$d"/* ]] && ok=1 && break
      done
      (( ok )) || ORPHAN+="  ORPHANTEST $f"$'\n'
    done < <(find YardKit/Tests -name '*.swift' -type f 2>/dev/null || true)
  fi
fi

# --- HANDROLLED: a hand-written allCases in production code ----------------
HAND=$(grep -rn -E 'static +(var|let) +allCases' Sources YardKit/Sources --include='*.swift' 2>/dev/null \
  | sed 's/^/  HANDROLLED /' || true)

for block in "$INERT" "$NARROW" "$TAUT" "$ORPHAN" "$HAND"; do
  if [[ -n "${block//[[:space:]]/}" ]]; then print -r -- "$block"; FOUND=1; fi
done

# SKIPSHAPE is advisory for now. Six instances already exist on main and are
# owned by #0105; failing the exit code on them would make every dispatch
# review report a defect unrelated to its own round, and a detector that is
# always red is a detector nobody reads. Promote it to a hard failure once
# #0105 lands.
if [[ -n "${SKIPSHAPE//[[:space:]]/}" ]]; then
  print -r -- "$SKIPSHAPE"
  print ""
  print "SKIPSHAPE is advisory (see #0105). A bare 'return' in a @Test body exits"
  print "before the assertions and reports success. Legitimate only if the test"
  print "genuinely cannot run — and then it should fail loudly, not skip."
fi

if (( FOUND )); then
  print ""
  print "Read each hit before acting. Ask of every test: what production change"
  print "would make this fail? If the answer is 'none', the criterion is not met"
  print "however green the run was."
  exit 1
fi
print "no inert tests found in: $TARGETS"
exit 0
