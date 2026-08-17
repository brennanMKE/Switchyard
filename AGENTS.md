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

## Rule 4b — Write your round's report to a file. The orchestrator commits it.

Rule 4 still holds: **you do not run git.** But your round ends in a commit on the issue branch —
made by whoever reviews it, the moment your round returns — and the message is yours.

Write `.switchyard-runs/NNNN-roundN.report.md` before you finish, with a heredoc:

```
cat > .switchyard-runs/0129-round1.report.md <<'MD'
Made the engine result types Encodable and pinned their wire shape.

Added CodingKeys to WhereAmI and Conflicts; swift test went 450 -> 456.
Could not test the reftable variant -- the fixture helper does not build one.
MD
```

**The first line becomes the commit subject. Write it as a commit subject:**

- **Imperative mood** — `Add`, not `Added`, not `Adding`.
- **Under 60 characters.** Longer is truncated with an ellipsis and reads badly.
- **No trailing period.**
- **Not a summary sentence.** The detail goes in the body, which is everything after line one.

Two consecutive rounds wrote a past-tense summary here and both subjects truncated mid-thought, so
this is spelled out rather than left to judgement. #0129 round 2 wrote a full sentence
and it was truncated mid-word. `Add Encodable conformance to WhereAmI` is right; *"Added the Encodable
conformance to WhereAmI with a private CodingKeys enum and three wire tests"* is not. Everything after
the first line is the body, and that is where the detail belongs. Say what you changed, what you ran, what it printed, and what
you could not do — the same report you would have written anyway, in a file instead of only in the
transcript.

If you write no report the harness still commits, using the tail of your log, which is worse for
whoever reads the branch later. Squash-merging to `main` records no ancestry, so **this commit is the
only lasting account of how the round went.**

## Rule 4c — Never `git stash`, `reset`, `checkout --`, or `clean` during a round.

**Your working tree is the deliverable.** There is no measurement worth destroying it for.

#0139 round 1 wrote its change, ran the suite, and got `Test run with 533 tests passed` — complete and
correct. It then decided 533 "did not match" the 530 the issue quoted as the *pre-change* baseline, ran
`git stash && swift test` to re-derive a number the issue had explicitly told it to trust, and left a
red tree. Its recovery, `git stash pop`, was chained behind `&&` with a `/tmp` path; the sandbox
rejected the whole line, so **the pop never ran**. A finished, green, correct round ended with its work
invisible in `stash@{0}`.

Two rules come out of that, and neither is checkable from the issue text:

- **Do not run destructive git commands.** Not `stash`, not `reset`, not `checkout --`, not `clean`.
  If you want a pre-change number, you needed it *before* you started; if you did not take it, say so
  in your report and move on. A missing baseline is a footnote. A destroyed working tree is the round.
- **Never chain a recovery step behind `&&` with anything touching a path outside the worktree.** The
  sandbox rejects the entire command line, and what gets lost is the recovery, not the thing that
  triggered the rejection. Run the recovery on its own line, first.

The number you are chasing is almost never worth what you would spend to get it.

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

## Rule 5c — Never `cat >` onto a file that already exists.

A heredoc is the right way to create a **new** file: six rounds have written 100-to-300-line new
Swift files that way with no truncation, and it sidesteps the `write` tool's output ceiling entirely.

**But `>` truncates before the heredoc streams.** If the heredoc is cut short, the original file is
already gone, and you are now repairing damage instead of doing the work. #0134 ran
`cat > YardKit/Sources/YardGit/WorktreeAdd.swift` on a 249-line existing file, the heredoc cut off
mid-file, and the file was destroyed. The repair attempt — another `cat >` — truncated again. Roughly
25 of that round's 29 shell calls were recovery, and it cost triple the tokens of its neighbours.

So:

- **New file** → `cat > path <<'SWIFT'` is fine and preferred. If it truncates you lose nothing: the
  compiler tells you immediately.
- **Existing file, adding to the end** → `cat >> path <<'SWIFT'`. Append cannot destroy what is
  already there, and it is what made the extension-collision traps in #0130 and #0131 unhittable.
- **Existing file, changing something in place** → the `edit` tool. That is what it is for.
- **Never** `cat >` onto an existing file. There is no case where it is the right instrument.

The `write` tool on an existing file is **not** covered by this rule and is fine. It fails
atomically: a rejected call writes nothing, which is what #0014 hit — 188 rejections and an intact
file. `cat >` fails *partially*, leaving a truncated file behind. The distinction is destructive-on-
failure versus safe-on-failure, not shell versus tool.

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

## Rule 9b — Your context is small. Read the issue and nothing else.

The usable input budget is about 44k tokens: `limit.context` 65,536 minus the 16,384 reserved for
output, and compaction fires near 90% of what remains. **When compaction runs, the first thing it
throws away is the issue's verbatim source block** — the pasted Swift that took a planning pass an
hour to compile and mutation-test. What comes back is a five-bullet prose summary, and a summary of
code is not code. You will then notice you are missing details and try to re-read the issue, which
compacts you again.

Two rounds died exactly this way on 2026-08-07: #0017 produced **zero writes** in twelve tool calls,
and #0019 got a source file out but ended asking to re-read its own issue.

So:

- **Do not read `AGENTS.md`.** You are reading it now. It is loaded automatically on every round, and
  re-reading it costs ~5k tokens to learn nothing. Measured: asked a question about this file with all
  tools forbidden, the model answered correctly with zero tool calls.
- **Do not read `issues/Issues.md`.** It is ~10k tokens of tracker process written for humans and
  reviewers — status lifecycles, commit conventions, review policy. None of it is your job. Your job
  is in the issue.
- **Do not load the `swift-guidance` skill when the issue already contains the Swift to write.** That
  source was authored with the skill loaded; it already conforms.
- **Do not glob or survey.** The issue names every file you need. If you are reading a file the issue
  did not name, you have already lost.

The budget you save is the budget you write with. A round that reaches its first write inside ten
tool calls converges; a round that spends its context orienting produces nothing at all.

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

### A fixture path and the path git reports back are not the same string.

`NSTemporaryDirectory()` returns `/var/folders/…`. `/var` is a symlink to `/private/var`, and **every
path git prints is the resolved form** — `/private/var/folders/…`. So this never matches:

```swift
let entry = entries.first { $0.path == repo.url.path }   // always nil
```

A round lost itself to this: its `try #require` on that lookup aborted every test before the
assertions it cared about could run, and the assertions therefore could not evaluate true for **any**
input.

`FixtureRepository.url` is now resolved at construction, so comparing against it works. If you build a
path yourself, resolve it the same way — with `realpath(3)`.

**Not with `resolvingSymlinksInPath()`.** That method is documented to *strip* a leading `/private`,
which normalises in the opposite direction. It looks like the right call and silently does nothing
useful here.

### Every file path you use must be worktree-relative. Never absolute. Reads included.

Write `YardKit/Sources/YardKit/CommandLineRunner.swift`, not
`/Users/brennan/Developer/brennanMKE/Git/switchyard-0124/YardKit/…`.

You are already in the worktree. An absolute path is a long string you have to reproduce from memory,
and **two rounds have been lost to getting one character of it wrong** — `brenbanMKE` and
`brenbananMKE` in place of `brennanMKE`. Both times the sandbox correctly read the mistyped path as
outside the worktree and auto-rejected the write:

```
! permission requested: external_directory (/Users/brennan/Developer/brenbanMKE/…); auto-rejecting
Error: The user rejected permission to use this specific tool call.
```

**That rejection is terminal.** The run ends there. In one of those rounds it happened on the final
edit, leaving the tree non-compiling with the work half-applied.

A relative path cannot be mistyped this way, because it is short and the parts you would get wrong are
not there.

**This applies to reads, and to your very first tool call.** The rule said "write" until 2026-08-08,
when a third round died the same way — `tensorshare` in place of `brennanMKE` — while **reading the
issue file itself**. One tool call, 21 seconds, nothing written, nothing attempted. The string
`tensorshare` appears nowhere in this repository; it was reproduced from memory and corrupted, which
is the same failure as the other two and simply landed earlier.

So: **read `issues/NNNN.md`, not `/Users/…/switchyard-NNNN/issues/NNNN.md`.** You are already in the
worktree when the round starts. There is never a reason to type the absolute prefix, and the only
thing typing it can do is end the round before it begins.

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
