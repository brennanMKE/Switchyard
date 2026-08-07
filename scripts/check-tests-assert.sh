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
#   NARROWING a loop over cases whose body discards all but one via
#             `guard case ... else { continue }`
#   TAUTOLOGY an assertion over literals, e.g. #expect(true)
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
      l=$0; n=gsub(/\{/,"",l); l=$0; m=gsub(/\}/,"",l); braces += n - m
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

# --- TAUTOLOGY: an assertion whose operands are literals --------------------
# #expect(true) passes no matter what the code does. Found in a round that had
# already been graded "no inert tests" — the body does contain an assertion
# macro, so the INERT scan above cannot see it.
TAUT=$(grep -rn --include='*.swift' -E '#(expect|require)\((true|false|1 == 1|0 == 0)\)' $TARGETS 2>/dev/null \
  | sed 's/^/  TAUTOLOGY  /' || true)

# --- HANDROLLED: a hand-written allCases in production code ----------------
HAND=$(grep -rn -E 'static +(var|let) +allCases' Sources YardKit/Sources --include='*.swift' 2>/dev/null \
  | sed 's/^/  HANDROLLED /' || true)

for block in "$INERT" "$NARROW" "$TAUT" "$HAND"; do
  if [[ -n "${block//[[:space:]]/}" ]]; then print -r -- "$block"; FOUND=1; fi
done

if (( FOUND )); then
  print ""
  print "Read each hit before acting. Ask of every test: what production change"
  print "would make this fail? If the answer is 'none', the criterion is not met"
  print "however green the run was."
  exit 1
fi
print "no inert tests found in: $TARGETS"
exit 0
