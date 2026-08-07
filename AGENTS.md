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
