# Review failures — what went wrong, and the check that prevents a repeat

Every dispatch round that failed review, with its root cause and the preflight check derived from it.
**Read the checklist before dispatching; add to it the moment a round fails.** The protocol that
governs this file is in `CLAUDE.md` § "Learning from failed reviews".

The point of this file is not history. It is the checklist in the second half — the table exists to
justify the checks and to stop them being quietly dropped as superstition.

A note on the pattern: most failures here are `spec-defect`. The local model has generally done what
it was told; the losses came from telling it something wrong, something impossible in its sandbox, or
too many things at once. **Assume a failed round is an authoring defect until the evidence says
otherwise.**

## Failure log

| Issue | Round | Symptom | Root cause | Class |
|---|---|---|---|---|
| #0010 | 1 | Watchdog killed it at 2400s; 83 `error:` lines; `Test run with` never appears; `main.swift` regressed with a force-unwrap ahead of its own guard | Asked for a metadata model **and** a help renderer **and** a schema emitter **and** a test in one round, and named zero source paths. The model got partway into each of four pieces. | `sizing` |
| #0011 | 1a | 58 green tests encoding `sessionTerminated = 4`, `requestFailed = 5` — inverted against the contract. The tests asserted the swapped values, so the suite was green while encoding the inverse. | The model invented the mapping. The spec was correct and unambiguous: `issues/0011.md` and guide §"Exit codes" both say 4 = request failed, 5 = session terminated. Not a spec defect. | `model-behaviour` |
| #0011 | 1b | Round reported success; the log contains no `Test run with` line at all | A mistyped path (`brenbanMKE`) put the test command outside the worktree, the sandbox auto-rejected it, and the model claimed success anyway. **OpenCode still exited 0** — exit 0 is not evidence. | `model-behaviour` |
| #0011 | 1c | `modified: ../CLAUDE.md` — the model added 11 lines of workflow doctrine to its own governing config | Scope violation. Predates `AGENTS.md` Rule 4, which exists because of it. | `model-behaviour` |
| #0011 | 2 | 64 green tests, exit codes fixed, and the stdout contract newly broken: `StandardStream.stderr` calls `Swift.print`, which writes to stdout, so `[error] …` precedes the JSON | Four deliverables again — **the same sub-criteria went unmet in both rounds**, which is the signature of an oversized issue. The round also contained two `signal 11` compiler crashes and a context compaction. | `sizing` (+ `model-behaviour`) |
| #0070 | 1 | Marked resolved on a read of a fluent 110-line document | The document asserted three false things about git trailers (`%trailers` is not a format atom; matching is case-**in**sensitive; the hard last-paragraph rule was omitted). The model **had** run real commands and was wrong about what their output meant. I reviewed by reading and agreed. | `review-defect` (+ `model-behaviour`) |
| #0070 | 2 | Exit 0 after 233s having changed nothing; caught only by the no-progress guard (exit 7) | My round-1 feedback told the model to *verify* git behaviour, which needs a scratch repo the sandbox denies. **The feedback itself made the round unrunnable.** | `review-defect` (+ `environment`) |
| #0085 | 1 | Correct code and 54 passing tests, but time burned on `ld: symbol(s) not found`, and the model edited `issues/0085.md` to match its own deviation | The issue named `YardKit/Sources/yard/CommandSpec.swift`; `yard` is an `executableTarget`, so `@testable import yard` does not link. The path was unbuildable. Four more issues carried the identical defect. | `spec-defect` (+ `model-behaviour`) |
| #0090 | 1 | Exit 0 after 1289s, rejected on review: 2 of 5 criteria failed. `Envelope.swift` rewritten from scratch — `EnvelopeFail`, `EnvelopeSchema`, `StandardStream`, `write()`, `terminate()` and `ExitCode.swift` all lost. Wire strings changed (`usage` → `usage_error`). A test named `allCasesRoundTripThroughJson` iterates `allCases` then `guard case .ok = code else { continue }` — it tests one case while appearing to test all. | The issue said "start from `issue/0011`, which has the enum", but the worktree was cut from `main`, which does not contain that branch's `Envelope.swift`. **`git merge-base --is-ancestor issue/0011 issue/0090` is false.** The model could not carry forward what was not there, so a one-field type change became a from-scratch reimplementation. The issue also named zero source paths. | `spec-defect` (+ `environment`) |
| #0086 | 1 | Exit 0 after 125s, both files at the right paths, no scope violations — rejected on two counts. `<argument>` was dropped for any flag that also had a short name (`-o, --output` instead of `-o, --output <PATH>`), and the eight new tests were XCTest in a swift-testing package, so `Test run with 54 tests` was **identical with both new files deleted**. | (a) The model read "flags render as `--long` or `-s, --long`, with `<argument>` appended" as three mutually exclusive forms rather than two prefixes plus an independent suffix, and wrote an if/else-if chain. Its tests were split so no test ever built a flag with *both* a short name and an argument — each half passed alone, and their conjunction, the only case that exposes the bug, was untested. (b) The issue never named the test framework. | `model-behaviour` (+ `spec-defect`, thin) |
| #0098 | 1 | Exit 7, 81s, nothing produced | The issue never said where the scratch image should go, so the model chose `/var/tmp`, which the sandbox auto-rejects. It then wrote "Now I have a clear picture. Let me execute the steps" and ended its turn having executed none of them. | `environment` (+ `spec-defect`, `model-behaviour`) |
| #0010, #0011, #0022 | — | Repeatedly failed to converge before being split | Each bundled four deliverables. No multi-deliverable issue has converged in this project; every converged issue named exactly one file. | `sizing` |

## Preflight checklist

Run before every dispatch, including re-dispatches. `[MECHANICAL]` checks are implemented in
`scripts/preflight-issue.sh` and enforced by `dispatch-issue.sh`, which refuses to dispatch on
failure. `[JUDGMENT]` checks require reading the issue.

Checks read the **spec only** — everything above the first `## Review`, `## Work log`, or
`## Sequencing` heading. Those sections discuss past defects on purpose.

### Mechanical — the script decides

| # | Check | Hard? | Derived from |
|---|---|---|---|
| 1 | Does it name a file inside an executable target? Nothing there can be unit-tested. | hard | #0085 |
| 2 | Does it direct work to `/tmp`, `/var/tmp`, or `$TMPDIR`? The sandbox auto-rejects those. | hard | #0070 r2, #0098 r1 |
| 3 | Does it name at least one concrete source file? | hard for code modules, warn otherwise | #0010, #0011, #0090 |
| 4 | Does it name a verification command whose output can be pasted as proof? | hard for code modules | #0011 r1 |
| 5 | Does it depend on a branch that is not an ancestor of `HEAD`? | hard | #0090 r1 |
| 6 | Does it ask the implementer to *discover* a fact rather than applying one? | warn | #0070 r2 |
| 7 | Are two dispatches already running? LM Studio is `PARALLEL 2`; a third queues silently. | warn | tooling |
| 8 | Round > 1 with an issue file unchanged since the last round, or with no `## Review` section. | hard (in `dispatch-issue.sh`) | #0070 r2 |
| 9 | Does the verification criterion state a baseline the count must exceed? | warn | #0086 r1 |

Check 3 is the strongest signal in the log: **every code round that failed named zero source paths;
every round that converged first try named exactly one.**

Check 5 skips lines that tell the implementer *not* to use a branch — guidance, not a base
requirement.

A green count is not evidence unless it *moved*. Check 4 now warns when an issue asks for
`Test run with N tests` without saying what N must exceed — #0086 satisfied the criterion literally
while its tests contributed nothing to the number.

### Judgment — read the issue and answer honestly

9. **Is there exactly one deliverable?** Not one theme — one file, one behaviour, one thing that is
   either done or not. If the Expected behavior names more than one new production file, it is more
   than one issue.
10. **Was every fact the issue asserts actually verified, by me, in this tree?** Not recalled, not
    inferred from a man page, and not true only on some other branch. #0090's description asserted
    that two types "already exist"; neither existed on the branch it was dispatched to.
11. **If the task integrates a tool's output, have I run that tool and written down what it actually
    produced?** `--help` documents the interface; only execution reveals the output shape.
    `icongen -p macOS` emits `AppIcon-macOS.appiconset` while Xcode expects `AppIcon` — absent from
    its help text, and it would have silently produced an icon set Xcode ignores.
12. **Can the named path hold a unit test?** A path is a claim about the build system; check it
    against `Package.swift`.
13. **Is any criterion satisfiable by an in-process approximation of an out-of-process contract?**
    #0011 wrote a test named `envelopeFailWriteEmitsJsonToStdout` that never calls `write()`. If the
    criterion is about what a *caller* observes — stdout bytes, exit status, a hook firing — say
    explicitly that a test which does not spawn a process cannot satisfy it.
14. **Do the tests exercise the *conjunction* of the criteria, or only each half?** #0086's tests
    covered "flag with a short name" and "flag with an argument" separately and never both at once —
    which is exactly the case its code got wrong. When a criterion has two independent dimensions,
    ask for the test that crosses them.
15. **Do the new tests actually assert?** The recurring inert-test pattern: a loop over `allCases`
    whose body `continue`s past everything but one case, and test functions containing zero
    `#expect`. Both look like coverage. Grep the diff for `#expect` per test function.

## Backlog debt this surfaced

Running the preflight across every open issue on the day it was written: **41 fail**. 41 name no
gradeable verification command; 29 name no source file. The M1 read commands were fixed in place —
they already named a file and lacked only the proof line, which is the same one-line addition in each.
The rest are M2 and M3 issues written as a plan rather than as a dispatch-ready spec.

**That backlog is not a bug to fix in bulk.** An issue is authored to dispatch standard when it
reaches the front of the queue, because authoring it earlier means authoring against a tree that will
have changed by the time it runs — which is exactly how #0090 round 1 failed. What matters is that
the debt is now *enforced* rather than discovered mid-round: `dispatch-issue.sh` will refuse each of
those 41 until it is written properly.

The one thing to carry forward: **the check found #0012 through #0020 all claiming coverage in prose**
("tested against both ref formats via the fixture harness") **without naming a command whose output
could be pasted.** That phrasing reads as rigour and grades as nothing.

## Already covered — do not add duplicate guards

| Failure mode | Existing guard |
|---|---|
| Dispatching from the wrong branch | `dispatch-issue.sh` branch check, exit 8 |
| A round's diff not attributable to it | `dispatch-issue.sh` clean-tree check, exit 4 |
| Looping forever on a task that will not converge | `dispatch-issue.sh` 3-round cap, exit 3 |
| A run hanging indefinitely | `dispatch-issue.sh` wall-clock timeout |
| A file named in an executable target | `dispatch-issue.sh` preflight, exit 9 |
| Copying GPL source from GitUp | `AGENTS.md` Rule 1 |
| Touching Apple signing assets | `AGENTS.md` Rule 2 |
| Claiming verification that did not happen | `AGENTS.md` Rule 3 |
| Committing, branching, or resolving | `AGENTS.md` Rule 4 |
| Retrying instead of stopping | `AGENTS.md` Rule 5 |
| Writing scratch files outside the worktree | `AGENTS.md` Rule 6 |
