# Switchyard — agent instructions

`CLAUDE.md` at the repo root is the canonical working agreement and this file must be kept in sync
with it. The two rules below are duplicated here **verbatim in substance** because they are
non-negotiable and a pointer is not good enough: violating either causes damage that is not a bug
and cannot be fixed by editing code.

Read `CLAUDE.md` in full before writing any code. Read `docs/switchyard-development-guide.md` for
scope and architecture, and `docs/switchyard-git-internals-and-undo.md` before touching the journal,
the ref layer, or worktrees. Tasks are in `issues/`; `issues/Issues.md` defines the workflow.

## Rule 1 — Licensing. Switchyard is MIT. GitUp is GPLv3.

`../GitUp` (relative to the repo root) is **GPL v3**, copyright 2015-2018 Pierre-Olivier Latour,
GitUpKit included. Switchyard is **MIT**. MIT output cannot carry GPL-derived code, which makes this
strict rather than optional:

- **Never copy GitUp source into Switchyard**, in any language.
- **Never translate GitUp Objective-C into Swift**, line by line or otherwise. That is a derivative
  work regardless of how it is phrased.
- **Never copy GitUp's test fixtures**, including the graph-layout DAG fixtures. Test data counts.
- **Do** read GitUp to understand *what a component solves* and *why it is shaped that way*, then
  close the file and design the Swift equivalent independently. Write the idea into `docs/` in your
  own words and implement from that note, not from the source.

`../../RemoteControl` is MIT by the same author. Its code **may** be copied and adapted freely;
retain the copyright notice where substantial portions are reused. The two sibling repositories have
opposite rules — confusing them is the most likely way this project acquires a legal problem.

If you are unsure whether something is derived from GitUp, stop and ask. Do not guess.

## Rule 2 — Never modify Apple signing assets.

- Do not pass `-allowProvisioningUpdates` or `-allowProvisioningDeviceRegistration`.
- Do not create, revoke, delete, or renew certificates or provisioning profiles — not via
  `xcodebuild`, `security`, `codesign`, `fastlane`, the App Store Connect API, or the developer
  portal. Never delete anything from a keychain.
- Do not change `CODE_SIGN_STYLE`, `CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM`, or
  `PROVISIONING_PROFILE_SPECIFIER` to make a signing error go away.
- **Build unsigned by default:** `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`.
- **Stop, do not retry**, on: `No signing certificate ... found`, `its private key is not installed
  in your keychain`, `errSecInternalComponent`, `User interaction is not allowed`, or any offer to
  revoke or replace a certificate. Drop to an unsigned build, diagnose read-only, then report and
  wait.

Certificate revocation is remote, account-wide, and irreversible. On 2026-07-24, repeated signed
builds against a sibling project drove Xcode to revoke and reissue the Apple Development certificate
twice.

## Rule 3 — Do not claim verification you did not perform.

"It compiles" is not verification. Tests must actually execute and pass, and you must read the
output rather than the exit code. If you could not run the verification step, say so plainly and
leave the issue open. A false claim of success is worse than an unfinished task, because it removes
the reason for anyone to check.

## Rule 4 — You implement. You do not commit, branch, or resolve.

You are dispatched one issue at a time, already on the correct `issue/NNNN` branch. Someone else
reviews your work, commits it, and decides when it is done.

- **Do not run** `git commit`, `git push`, `git add`, `git switch`, `git checkout`, or `git branch`.
  Leave your changes in the working tree.
- **Do not change the issue's `Status` row.** Review decides that.
- **Do not start another issue**, however tempting or related it looks. One issue per run.

## Rule 5 — Stop instead of retrying. A clear stop is a good outcome.

If you are blocked, or you notice you are about to repeat an action that already failed, **stop and
report**. Say what you tried, what happened, and what you think is needed. That report is genuinely
useful — it becomes the feedback that makes the next round work.

Repeating a failing command with small variations is the one failure mode that wastes the most time
here, because the run is on a wall-clock timeout and gets killed with nothing to show. If two
attempts at the same thing have failed, the third will not succeed; write the report instead.

Finish every run with: what you changed, what you ran, what it printed, and what you could not do.

## Rule 5b — A tool call that failed the same way twice will not succeed on the third try.

Rule 5 covers shell commands. This is the same rule for **tool mechanics**, and it has cost a whole
round: a `write` call was emitted with no `content` key, rejected, and re-emitted **188 times over
25 minutes** until the timeout killed the run. Nothing was produced. The reasoning behind it was
correct and was lost with it.

- **Two identical failures is the signal to change approach**, not to retry harder.
- **If `write` fails twice on the same file, use a shell heredoc**: `cat > path/File.swift <<'EOF'`
  … `EOF`. It does not go through the same schema and it works.
- **Prefer building a large new file incrementally.** Declare the types, run `swift build`, then add
  the methods. A partial file that compiles can be finished; a 300-line write that never lands leaves
  nothing behind.
- If neither path works, **stop and say which tool failed and how**. That is a useful round. Twenty
  minutes of identical retries is not.

## Rule 6 — Every scratch file goes in `build/`, inside the worktree.

Your sandbox auto-rejects writes to `/tmp`, `/var/tmp`, and anything outside the working directory.
This is not negotiable and there is no permission to request — a run that tries it gets a hard
rejection and produces nothing.

Intermediates, downscaled images, generated trees, scratch output: all of it goes under `build/` in
the worktree. It is already in `.gitignore`, so it will not pollute the diff. Create it if it is not
there.

Two separate runs have now died on this. If a command is rejected, **retry it inside the worktree** —
do not describe the remaining steps and end your turn. A plan is not an outcome.

## Rule 7 — A test that cannot fail is worse than no test.

Two rounds have now shipped tests that look like coverage and assert nothing. Both were green. Both
hid a real defect.

The two shapes to never write:

- **A loop that skips almost everything.** `for code in allCases { guard case .ok = code else
  { continue }; ... }` iterates every case and tests exactly one, under a name promising all of them.
  If you loop over cases, every iteration must reach an assertion.
- **A test function with no assertion at all.** If it contains no `#expect`, it passes
  unconditionally and proves nothing.

Also: **the name must match what the body does.** A test called
`envelopeFailWriteEmitsJsonToStdout` that never calls `write()` is a false claim in the test report,
and it survived review once precisely because the name was read instead of the body.

**If a test extracts something before asserting on it, assert the extraction is non-empty first.**
A helper that silently returns an empty collection turns every following assertion into `[] == []`,
which passes unconditionally. This has happened: a key-order test whose extractor assumed a 4-space
indent against 2-space output returned nothing, and both its assertions passed while testing nothing.
`#expect(!extracted.isEmpty)` first, then compare.

**Never write `#expect(true)`**, or any assertion whose operands are literals. It passes no matter
what the code does.

**Enumerate cases with `CaseIterable`, never a hand-written array.** A hand-written list means the
next case someone adds is silently untested and nothing fails. If the name says *all*, *every*, or
*each*, assert the collection's count first so the loop cannot silently run zero times.

Before you finish, re-read each test you wrote and ask what change to the production code would make
it fail. If the honest answer is "none", the test is not done.

## Rule 3b — Run the test suite before you stop, even if you are out of time.

A round has shipped a **red** suite: two of its own tests failed, and it never ran them. The budget
went into a debug loop printing per-character output. One `swift test` would have shown both
failures.

An incomplete implementation is a fine outcome — say what is unfinished and stop. A **finished-looking
implementation with failing tests is worse**, because it reads as done and the failure is only found
later by someone else.

So: run the verification command as your last action, always. If it fails and you cannot fix it,
report that it fails and what the failure says. Never end a round without knowing the state of the
suite.

## Rule 8 — Tests use swift-testing, not XCTest.

Every test file in this package uses `import Testing`, `@Test`, and `#expect`. Match it.

This is not style. `swift test` prints one summary line — `Test run with N tests` — and **that line
counts only swift-testing tests.** A round once added eight XCTest cases and reported "54 tests = 8
new + 46 existing"; the real count was 54 either way, and deleting the new file changed nothing.
The tests ran and passed on a different channel, invisible in the number the issue asked for.

So: `import Testing`, `@Test func name()`, `#expect(...)`. Never `import XCTest`, `XCTestCase`, or
`XCTAssert*`. If the count in your paste does not go up, your tests are not in the run being counted.

## Rule 8b — A test file outside a declared target path is never compiled.

`YardKit/Package.swift` declares exactly two test target paths:

```
Tests/YardGitTests     — tests for the YardGit target
Tests/YardKitTests     — tests for the YardKit target
```

**A `.swift` file anywhere else under `Tests/` is invisible to SwiftPM.** It is not an error and there
is no warning. `swift build` succeeds, `swift test` succeeds, the summary line does not move, and your
tests have never run.

A round wrote its tests to `Tests/YardGit/` — one character different from `Tests/YardGitTests/` — and
reported `Test run with 216 tests` as proof of success. 216 was the count *before* the change. The
whole round was lost. Relocated into the real target the same tests produced twenty compile errors,
every one an API that does not exist, because nothing had ever tried to build them.

So, before you finish:

```sh
ls YardKit/Tests/          # must print exactly: YardGitTests  YardKitTests
```

If any other directory appears there, your tests are not being compiled, whatever else is true. And
the count in your paste must be **greater** than the count you measured before you started — an
unchanged count is the signature of this exact mistake.

## Rule 9 — Never end a round with a question.

You have no one to ask. The round runs unattended; whatever you ask goes into a log nobody reads
until after you have stopped, and the round is scored as if you had refused to do the work.

A round once wrote its source file correctly, listed its own four remaining steps — write the tests,
run them, run the mutations, report — and ended with *"Would you like me to proceed with step 1?"*. It
knew exactly what was left. The whole round was rejected, because none of the four mutations the issue
required could run against a file with no tests.

If something is genuinely ambiguous:

1. **Do every part that is not ambiguous, first.** That is almost always most of the work.
2. Pick the reading that satisfies the issue's Expected behavior most literally, and implement it.
3. Say what you assumed at the **end**, in one sentence, after the work is done and the suite has run.

An unanswered question at the end of a finished round is useful. A question instead of a finished
round is a stop, and a stop is the one outcome that cannot be reviewed.

## Rule 7b — Bind with `try #require`, never with `if let`, in a test.

```swift
if let entry = entries.first(where: { $0.path == wanted }) {
    #expect(entry.locked == false)          // ← skipped entirely when the entry is absent
}
```

When the lookup fails, the block does not run, the test asserts nothing, and it **passes**. That is
the failure it was written to catch, reported as success. An `else` branch containing only a comment
is the same bug with more characters.

```swift
let entry = try #require(entries.first(where: { $0.path == wanted }))
#expect(entry.locked == false)              // ← now a missing entry fails the test
```

`#require` fails the test when the value is absent, which is the whole point of looking it up. One
round shipped five of these in a single file.

The same applies to two shapes nearby:

- **`#expect(a || b)`** passes when either half holds, so neither is actually being tested. Assert
  them separately.
- **`_ = result.something`** asserts nothing at all. If it is worth reading, it is worth asserting on;
  if it is not, delete it.

`scripts/check-tests-assert.sh` now flags the comment-only `else`. It cannot see the other two — those
are yours to avoid.

### `#expect(x != nil)` then `x!` destroys the whole run

`#expect` **records an issue and keeps going.** It does not stop the test. So this:

```swift
#expect(entry != nil, "the entry should be there")
let path = entry!.path                       // ← traps when it isn't
```

does not fail one test — it kills the test **process**. swift-testing emits no
`Test run with N tests` line at all, and every other test's result is lost with it. A round died
exactly this way, having written the pattern three times in one file.

```swift
let entry = try #require(entries.first { … })   // stops the test if absent
let path = entry.path
```

`#require` is `#expect`'s stopping sibling. Use it for every optional you are about to unwrap.

### Never capture stdout in a test.

```swift
let pipe = Pipe()
dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
let data = pipe.fileHandleForReading.readDataToEndOfFile()   // ← blocks forever
```

The write end stays open, so EOF never arrives and the read never returns. Worse, you have just
redirected the **test runner's** stdout into your pipe, so swift-testing's own output goes into the
void — the suite produces no `Test run with N tests` line and every other test's result is lost.

A round shipped this and its suite ran for 10 minutes 50 seconds without emitting a single line,
against a 12-second baseline.

If you need to test what a function writes, **do not test the writing — test the value.** Make the
helper that produces the string `internal` instead of `private` and call it directly under
`@testable import`. A function whose only output is a side effect on a global file descriptor is not
testable, and making it testable is a smaller change than capturing the descriptor.

`grep -rn 'dup2' YardKit/Tests/` must return nothing.

Reading a **subprocess's** pipe to EOF is fine — the child exits and closes the write end. The hazard
is `dup2` on your own `STDOUT_FILENO`.

### After a context compaction, re-read the issue before you act.

If your context was summarized mid-round, **the summary is not a record of what happened.** One has
already invented three prior rounds, a fourth review, and a list of test names that did not exist —
and the model worked from all of it, including re-importing a sandbox rejection from a previous round
as a live instruction.

`issues/NNNN.md` on disk is the record. Re-read it. It contradicts anything the summary got wrong.

The same round also discarded the correct fix, which the summary *did* contain, and went back to
re-deriving a diagnosis the issue had already measured. **If the issue states a measurement, do not
re-measure it** — and in particular, do not run the test suite before you have written anything. Two
full `swift test` runs is roughly 50 KB of output; piping that into context before doing any work is
what forced the compaction in the first place.

### A "Mutation:" instruction is for the REVIEWER, not for you to encode as a test.

When an issue says

> **Mutation**: remove `.sortedKeys` and confirm the test fails.

that describes something **the reviewer does to the production source after your round**, to check
your test is load-bearing. It is **not** a request for a test that reproduces the mutated behaviour.

A round once read it the other way and wrote two tests that built a deliberately-broken encoder and
asserted its output was *not* sorted. Unsorted order is random, so those tests failed about five runs
in six -- and they touched no production code, so deleting the real fix would not have failed them.
Flaky and inert at the same time.

**Write the test that passes when the code is right.** Make it fail hard when the code is wrong:
assert the exact expected value, not a property the wrong answer might also satisfy. If the correct
output is a specific string, compare the whole string.

## Rule 10 — `swift build` does not compile the tests. Only `swift test` does.

`swift build` builds the library and executable targets. It does **not** build test targets. A test
file with a syntax error, a missing import, or a variable used out of scope compiles nowhere, and
`swift build` still prints `Build complete!` — in under a second, because there was nothing new to do.

A round once read that, concluded the suite was green, and shipped a test file containing
`cannot find 'fm' in scope`. Every mutation the issue required was unrunnable. The whole round was
lost.

**Verification is `swift test`. Always.** And:

**A `swift test` run with no `Test run with N tests` line is a failure.** Not a warning, not an
ambiguity, not something to investigate further — the suite did not build. If you grep the output for
that line and get nothing, *that is the answer*: the run failed. Print the last thirty lines of the
raw output and read the first `error:` in them.

Do not treat an empty grep as inconclusive. An expected line that is absent is a finding, not a
missing view of one.

## Build commands

```sh
# Package tests — the primary suite, touches no signing assets
cd YardKit && swift build && swift test

# Unsigned compile check
xcodebuild build -project Switchyard.xcodeproj -scheme Switchyard \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet

# Unit tests only — UI tests cannot run headless here
xcodebuild -project Switchyard.xcodeproj -scheme Switchyard \
  -destination 'platform=macOS' -only-testing:SwitchyardTests test
```

`YardKit/` does not exist yet. The repository is a stock SwiftUI template plus documents and tasks.
