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
#   EMPTYELSE an `else` block containing only comments — the `if` branch's
#             assertion is simply skipped when the condition does not hold
#   EXPECTBANG `#expect(x != nil)` then `x!` — #expect does not stop, so the
#             force unwrap traps and takes the whole run summary with it
#   STDOUTCAPTURE `dup2` / `readDataToEndOfFile` — blocks forever and hijacks
#             the runner's own stdout, so the suite reports nothing at all
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

# --- EMPTYELSE: an `else` block that asserts nothing ------------------------
# `if let x { #expect(...) } else { /* not present */ }` passes when x is
# absent -- the assertion is skipped and the test reports success. #0096
# round 2 shipped five of these. The right shape is `try #require(...)`, which
# fails when the value is missing.
#
# Brace-balanced from `else {` to its close, counting only from the `else`
# keyword onward -- the `}` in `} else {` closes the *previous* block, and
# counting it was the bug that made the first version of this scan never fire.
EMPTYELSE_AWK=$(cat <<'AWKEOF'
{
  line = $0
  gsub(/"([^"\\]|\\.)*"/, "\"\"", line)          # strip string literals
}
depth > 0 {
  body = body "\n" line
  n = gsub(/{/, "{", line); m = gsub(/}/, "}", line)
  depth += n - m
  if (depth <= 0) { report(); depth = 0; body = "" }
  next
}
{
  # Find `else {` and count braces only from there onward.
  tail = line
  if (sub(/^.*[^A-Za-z0-9_]else[ \t]*{/, "{", tail) || sub(/^else[ \t]*{/, "{", tail)) {
    start = NR; body = tail
    n = gsub(/{/, "{", tail); m = gsub(/}/, "}", tail)
    depth = n - m
    if (depth <= 0) { report(); depth = 0; body = "" }
  }
}
function report(   s) {
  s = body
  gsub(/\/\/[^\n]*/, "", s)
  gsub(/[ \t\n{}]/, "", s)
  if (s == "") printf "  EMPTYELSE  %s:%d: else block asserts nothing\n", F, start
}
AWKEOF
)
EMPTYELSE=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  EMPTYELSE+="$(awk -v F="$f" "$EMPTYELSE_AWK" "$f" || true)"$'\n'
done < <(find $TARGETS -name '*.swift' -type f 2>/dev/null || true)
EMPTYELSE=$(print -r -- "$EMPTYELSE" | grep . || true)

# --- EXPECTBANG: `#expect(x != nil)` followed by `x!` ----------------------
# `#expect` records an issue and KEEPS GOING. So the force unwrap on the next
# line traps, the test *process* dies, and swift-testing emits no
# `Test run with N tests` line at all -- every other test's result is lost
# with it. #0096 round 3 died this way, with the pattern written three times
# in one file. `try #require` is the stopping sibling.
EXPECTBANG_AWK=$(cat <<'AWKEOF'
# Remember the identifier from `#expect(<ident> != nil` and flag a force
# unwrap of that same identifier within the next few lines. #expect records
# and continues, so the `!` traps and kills the whole test process.
{
  buf[NR] = $0
  if (match($0, /#expect\([A-Za-z_][A-Za-z0-9_]*[ \t]*!=[ \t]*nil/)) {
    s = substr($0, RSTART + 8)
    sub(/[ \t]*!=.*/, "", s)
    pend[NR] = s
  }
}
END {
  for (n in pend) {
    id = pend[n]
    for (j = n + 1; j <= n + 6 && j <= NR; j++) {
      if (buf[j] ~ ("(^|[^A-Za-z0-9_.])" id "![^=]")) {
        printf "  EXPECTBANG  %s:%d: #expect(%s != nil) then %s! at line %d\n", F, n, id, id, j
        break
      }
    }
  }
}
AWKEOF
)
EXPECTBANG=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  EXPECTBANG+="$(awk -v F="$f" "$EXPECTBANG_AWK" "$f" || true)"$'\n'
done < <(find $TARGETS -name '*.swift' -type f 2>/dev/null || true)
EXPECTBANG=$(print -r -- "$EXPECTBANG" | grep . || true)

# --- STDOUTCAPTURE: dup2 / readDataToEndOfFile in a test ---------------------
# Redirecting THIS process's stdout into a Pipe and reading to EOF blocks
# forever -- the write end stays open -- AND swallows the test runner's own
# output, so the suite emits no `Test run with N tests` line and every other
# test's result is lost. One round ran 10m50s this way against a 12s baseline.
#
# Only `dup2` is the hazard. Reading a *subprocess's* pipe to EOF is normal and
# safe, because the child exits and closes the write end -- the first version of
# this scan flagged seven legitimate `readDataToEndOfFile` calls in
# YardBinaryContractTests and would have been switched off within a day.
STDOUTCAPTURE=$(grep -rn --include='*.swift' -E '\bdup2\b' $TARGETS 2>/dev/null \
  | sed 's/^/  STDOUTCAPTURE  /' || true)

# --- HANDROLLED: a hand-written allCases in production code ----------------
HAND=$(grep -rn -E 'static +(var|let) +allCases' Sources YardKit/Sources --include='*.swift' 2>/dev/null \
  | sed 's/^/  HANDROLLED /' || true)

for block in "$INERT" "$NARROW" "$TAUT" "$ORPHAN" "$EMPTYELSE" "$EXPECTBANG" "$HAND"; do
  if [[ -n "${block//[[:space:]]/}" ]]; then print -r -- "$block"; FOUND=1; fi
done

# SKIPSHAPE is advisory for now. Six instances already exist on main and are
# owned by #0105; failing the exit code on them would make every dispatch
# review report a defect unrelated to its own round, and a detector that is
# always red is a detector nobody reads. Promote it to a hard failure once
# #0105 lands.
# STDOUTCAPTURE is advisory until #0114 lands. One instance exists on main --
# JsonEnvelopeTests dup2s stdout to test EnvelopeFail.write() -- and it happens
# to terminate, so failing the exit code on it would make every dispatch red
# for a hazard that has not yet fired there. #0114 replaces it.
if [[ -n "${STDOUTCAPTURE//[[:space:]]/}" ]]; then
  print -r -- "$STDOUTCAPTURE"
  print ""
  print "STDOUTCAPTURE is advisory until #0114 lands. dup2 on your own STDOUT_FILENO"
  print "redirects the TEST RUNNER's output, so a suite can finish with no"
  print "'Test run with N tests' line at all -- every result lost, not just that"
  print "test's. And a Pipe read to EOF never returns, because the write end"
  print "stays open. Test the value, not the writing."
  print ""
fi

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
