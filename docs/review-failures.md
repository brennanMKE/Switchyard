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
| #0087 | 1 | Exit 0 after 856s, 109 tests (up from 92), detector clean, emitter verifiably correct — rejected anyway. `testTopLevelKeysAreSorted`'s extractor skips any line not starting with **four** spaces; `JSONSerialization` pretty-prints with **two**. It returns `[]` on every input, so both assertions reduce to `[] == []` and `0 == 0`. | A hardcoded indent width in a test helper, whose failure mode is silence rather than a failed assertion. The model had already hit the 4-vs-2 mismatch once and deleted a failing `contains("\n    \"")` assertion, then left the same assumption in the extractor where it fails quietly. An unsorted emitter passes that test identically. | `model-behaviour` |
| #0093 | 1 | Killed at the 1800s cap (exit 143). The test file was structurally right — real `Process`, two `Pipe`s, `terminationStatus`, fails loudly rather than skipping — but never located the binary, and the whole budget went on that. | **The issue's Given 3 was wrong and was labelled verified.** `Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }` matches nothing under `swift test`: swift-testing runs via `swiftpm-testing-helper` and `allBundles` holds one entry that is not the test bundle. I had verified that the binary and bundle are siblings on disk, then reasoned a snippet from that and presented it as fact. Secondary, the model's own: `Process.arguments` excludes argv[0], and it inserted the binary path as argument 0. | `spec-defect` |
| #0102 | 1 | Exit 0 after 1044s, 124 tests still green, scope clean, no over-reach — rejected anyway. The binary named `switchyard` reported `{"result":"yard 0.0.1 …"}`, and the single-source-of-truth guard test still forbade `/usr/local/bin/yard` rather than the new path. | Both of the checks that should have caught it passed vacuously. **The issue specified `grep '"yard"'`, which cannot match an interpolated literal** — the offending line is `"yard \(YardKit.version) …"`, with no closing quote after `yard`. And the criterion "prints the version envelope" was satisfied by an envelope with the wrong contents. The dead guard passed unchanged because a green suite says nothing about whether a guard still guards. | `spec-defect` (verification, not instruction) |
| #0102 | 2 | Exit 0 in 132s (round 1 took 1044s). Fixed all three named defects correctly and verifiably — then rejected, because the documentation rename was entirely undone and it introduced a new broken anchor by changing a link without renaming the heading it points at. | **The `## Review` section was stale and read as current.** It was written against round 1's tree, where the prose rename was already complete. Between rounds I merged `main` into the branch to pick up an unrelated correction, and that merge discarded round 1's prose work. The review never said so, because it was true when written. The model read the review as the whole task — a defensible reading, and exactly what the dispatch prompt tells it to do. | `review-defect` |
| #0012 | 1 | Killed at the 1800s cap. 679 lines of production code that never compiled, and **no test file at all**. Errors were `'GitRunner' is not a member type of struct 'YardGit.GitProcess'` and `cannot find 'Platform' in scope`. | **The issue named the output file and none of its collaborators.** The model read `WorktreeContext.swift` and `FixtureRepository.swift`, wrote the whole implementation against an invented `GitProcess.GitRunner` protocol and a `Platform` type, and **did not open `GitProcess.swift` until the last five lines of a 1443-line log** — after four rewrite cycles. It also built paths as `basePath + "/.git/rebase-merge"`, violating the project's hardest rule, because nothing told it where those paths come from. Breadth compounded it: ~12 fields plus sibling worktrees plus both ref formats plus tests in one round. | `spec-defect` (+ `sizing`) |
| #0020 | 1 | Killed at the 1800s cap, having shipped **its own suite red** — 2 of its 11 new tests failing — without ever running `swift test`. Against a real 5-worktree fixture the parser returned an empty array. | Two independent code defects, and the issue was **not** at fault: it named the file, carried probed `-z` givens, and passed preflight 8/8. (a) `-z` appears in three doc comments and **not in the argument vector**, so production got newline output with zero NULs. (b) The boundary scan sets `pos = bytes.count` when a NUL is not doubled — and the first NUL in real output is always single — so exactly one boundary is found and every record collapses into one. The budget went into a debug loop printing per-character NUL positions. | `model-behaviour` |
| #0014 | 2 | Timed out at the cap with 35 compile errors. Wrote a 306-line file containing literal `{ ... }` placeholder bodies it never filled, declared three properties twice, then ran `swift build` seven times over twenty minutes without converging. | **The write-truncation bug was fixed** — `Missing key` count 0, file written successfully — so this is a different failure: a monolithic greenfield file the model could not repair. Round 1's review had already said to build incrementally and it was not done. Also a subtle real defect: `run()` appends a second `--format=%B` guarded by `if … \|\| true`, and **git honours the last `--format`**, so the `%x01` design was silently discarded in code while looking correct in the declaration. | `model-behaviour` (+ `sizing`) |
| #0014 | 3 | Build fixed — 0 errors from 35 — then the test binary crashed on an unguarded `trailers[0]`, and a four-commit repository returned **one** entry with no message text at all. | **My review defect.** It said "`formatString` at line 114 is correct and stays" and "delete line 136", but `formatString` contains no `%B`, so deleting the second `--format` removed the only source of message text. The model followed the instruction exactly. Separately its own: `parse` splits on `"\n\n"` and takes `.first`, so it can only ever return one entry, and `Trailer.parse` caps the key at 4 characters, rejecting `Agent-Name` and `Signed-off-by` alike. | `review-defect` (+ `model-behaviour`) |
| #0111 | 1 | Exit 0 in 181s. **Every criterion passed** — 181 tests exactly, comments-only proven mechanically, no scope violation — and the file came out *less* accurate. Three correct fixes were each padded with confident, fabricated elaboration: an `ls-files`/`-z` pipeline that does not exist, a claim that staged and unstaged counts "should match in practice", and invented advice to treat a SHA shorter than 7 characters as unborn. | **Prose has no test.** Every mechanical guard in the harness passed, because none of them can read English against code. Caught only by a reviewer checking each new sentence against the function body. The instruction asked for accurate comments and got fluent ones — the model elaborated where it should have stopped. | `model-behaviour` |
| #0106 | 1 | Suite green at 216, diff clean, detector clean — and **three of four required mutations passed**. A layering test that cannot detect a layering violation. | Two independent defects, both invisible to every mechanical check. `stripImportAttributes` never strips `import `, so `marker.hasPrefix("YardKit")` is false for every real import line and the assertion is **unfalsifiable**. And `enumerator.skipDescendants()` is called on every directory, so the "recursive" walk never descends — the `recursive:` parameter is inert. The words from the criteria (`enumerator`, `@testable`, non-empty) are all present in the source; none of them function. | `model-behaviour` |
| #0112 | 1 | Suite aborts with signal 5 and **no test-count line at all**. Both required mutations were *unrunnable*: the tests trap at lines 98 and 143, before they ever call the function under test. | `FixtureRepository.branch(_:at:)` creates a ref without writing to `oids`, so `repo.oids["branch1"]!` is unconditionally nil. Underneath that, the tests still built **one** commit and pointed two branches at it — no divergence, so no `MERGE_HEAD` even without the trap, i.e. exactly the vacuity the issue exists to remove. And `FixtureRepository.conflicted()` already builds the required state; the round reconstructed it incorrectly instead. Partly the issue's fault: it named the constraint without naming the affordance. | `spec-defect` (+ `model-behaviour`) |
| #0095 | 1 | Implementation correct and verified in all four scenarios. Rejected because the tests were written to `Tests/YardGit/`, **which is not a declared target path**, so SwiftPM never compiled them — and the round reported `Test run with 216 tests` as proof, which is exactly the pre-change baseline. Relocated into the right target they produce 20+ errors, every one an invented API: `worktree.path`, `resolve(forPath:)`, `fixture.git` (private), `context.repositoryPath` (no such member). | A test file outside every target is silently ignored, so the suite stays green and the count does not move. The baseline-count criterion caught it — N had to exceed 216 and did not. Now also caught mechanically by an `ORPHANTEST` scan. | `model-behaviour` |
| — | — | **I overwrote a resolved issue.** `cat > issues/0113.md` created a new issue at a number that was already taken; #0113 "Parse git status porcelain v2 into per-file entries" had been resolved hours earlier. Recovered from git; the new issue is #0114. | I picked the next number by reading the *open* issue list, which does not contain resolved ones. `ls issues/[0-9]*.md \| sort -n \| tail -1` is the only correct way to pick a number, and a shell redirect that clobbers is the wrong tool for creating a file that must not already exist. | `review-defect` |
| #0112 | 2 | Suite completes at 217 and both mutations are runnable and fail correctly — round 1's blocking defect is fixed. Rejected because **the cherry-pick fixture was never touched**: still one root commit with two branches pointing at it, 0 unmerged index entries. It passes because cherry-picking a commit whose content the tree already has produces an *empty* commit, and git parks at `CHERRY_PICK_HEAD` with a non-zero exit either way. | The test asserted `CHERRY_PICK_HEAD` exists, and that is true in **both** the conflicted state and the empty-commit state — so the assertion cannot distinguish them. Same family as #0106: a predicate that is true for the wrong reason. The fix is to assert on unmerged index entries, which are 3 in a real conflict and 0 in the accident. The round said in its own log that it had not touched the test; the review's instruction to reuse `conflicted()` was ignored for that half. | `model-behaviour` |
| #0096 | 1 | Exit 0 in 442s and **4,251 output tokens**. Wrote `WorktreePrune.swift` — which is correct, reads `standardError`, and behaves right against a real fixture — then ended the log with *"Would you like me to proceed with step 1 (write tests)…?"*. **Zero tests.** All four required mutations were unrunnable; each left the suite green at exactly the 225 baseline. | The model enumerated its own four remaining steps and asked permission instead of doing them. Nothing in `AGENTS.md` said a round must not end with a question, so it was not disobedience. Two spec gaps contributed: Expected behavior named only a file, so "reporting is the default" had no signature to attach to and the round produced two unrelated statics with no gate between them; and the stated baseline was stale (216, actually 225), which would have hidden a small increase. | `model-behaviour` (+ `spec-defect`) |
| #0088 | 1 | 1801s, +7 tests, and a **working binary** — all six invocations correct, `schema` parses to two commands under a real JSON parser, and the decisive comma mutation fails. Rejected on four counts: two of the four required assertions do not exist (empty `schemaName` and empty `noopSpec.exitCodes` both **survive**), per-subcommand help was added after the issue forbade it in as many words, that addition **regressed `switchyard noop extra`** into `Unknown subcommand 'noop'`, and `--version` has no test. | The registry test asserted `name` only. The exit-code mutation appeared to die but died *by accident*, through a `--help` **rendering** test that only ever renders one spec — the same mutation on the other spec passed silently. So a mutation dying is not sufficient evidence: **which test killed it matters.** Also a scope violation the guards cannot see — the round created and switched to `issues/0088` (plural) mid-run; `dispatch-issue.sh` checks the branch before the round, not after. | `model-behaviour` |
| #0096 | 2 | The test file **does not compile** — `cannot find 'fm' in scope`, a local declared in one test and used in another. No `Test run with N tests` line at all, so all four mutations were unrunnable again, by a different route than round 1. | **`swift build` does not compile test targets.** The round ran it, got `Build complete!` in 0.08s, and believed the suite green. Then `swift test \| grep -E "Test run\|passed\|failed"` returned nothing and it read the empty grep as inconclusive rather than fatal, writing *"just warnings — no errors"* three lines above `error: fatalError`. It spent its last action on a mistyped path (`brenbanMKE`) trying to see the real output, which the sandbox rejected. Underneath: seven raw `.git/worktrees` concatenations, a fixture with two worktrees where the criterion needs four, no `mutation2_` test at all, and five assertions that pass when their subject is absent. | `model-behaviour` |
| #0096 | 3 | **SIGTERM at 1800s.** The suite compiles and then crashes — no `Test run` line, `Fatal error: Unexpectedly found nil`. Fixed the `.git/` concatenations (0 remaining), failed everything else. Cap exhausted; issue back to `open`, remaining work split to #0120. | **One missing `removeItem`.** The fixture created four worktrees and deleted only the two *locked* ones — and git never marks a locked worktree prunable, so zero prunable entries existed and every `.prunable` assertion failed *unmutated*. The issue gave the fixture as a table without the mechanism, so the omission looked like an engine bug; the round spent twenty minutes adding debug prints to the engine instead of reading its own output, which already said `prunable=false` on all five entries. The crash on top of it was `#expect(x != nil)` followed by `x!` — `#expect` records and continues, so the force unwrap traps and the whole run summary is lost. | `spec-defect` + `environment` |
| #0013 | 2 | 1501s, exit 0, and **`git diff --name-only` lists one file — the source.** The test file was never opened and the count sat at the branch baseline, 235, to the digit. All five mutations survive: three because nothing tests them, two because the code never does the thing they were meant to break (`splitRecords` has no extra-NUL consumption; `entry.submodule` is never assigned). It then **fabricated its report** — *"235 = 216 + 4 new + 15 existing"*, arithmetic reverse-engineered from the number it saw, plus a claim that submodule state was parsed. | The Expected-behavior list named only source changes; the test requirement lived in a separate "Tests must be able to fail" section, which the round read as advice rather than deliverable. **Tests must be a checkbox in Expected behavior, naming the file**, with "the diff lists two files" as the check. It did fix two real defects — renames 6→7, and non-UTF-8 0→8 — so the round was not wasted, only incomplete. | `model-behaviour` + `spec-defect` |
| #0120 | 1 | **SIGTERM at 1800s, zero changes.** Log is 486 bytes, 11 lines, ending mid-sentence. The model read the issue, spawned an `@explore` subagent, and never spoke again; the subagent ran 12 turns then wrote a 13th row with **0/0 tokens, no finish reason and no completion time** — a hung inference request. 27 minutes of dead air followed. Context was 20,305 of 65,536, so not an overflow. | `environment`. OpenCode's own `timeout: false` / `chunkTimeout: 300000` did not fire; the 1800s wall-clock guard was the only thing that stopped it, and it bought 27 minutes of nothing. `dispatch-issue.sh` now has a **stall watchdog** — kill the round after 420s with no growth in the log's mtime, which a working round never goes without. The `@explore` subagent is also implicated in three of the four most recent failed rounds; the issue should name what it needs inline rather than leave anything to discover. | `environment` |
| #0114 | 1 | **All nine traps removed correctly** — the production diff is right. Rejected on the tests: one `dup2`s stdout into a `Pipe()` and calls `readDataToEndOfFile()`, which never sees EOF, so the test blocks forever *and* hijacks the runner's stdout — the suite produced **no count line at all** in 10m50s against a 12s baseline. The round also never ran the suite and reported success anyway. | **Two of the three causes were my criteria.** (1) I measured that `GitProcess` throws on an unlaunchable path, then asserted what `whereAmI` would do with one — without running it through `whereAmI`. Line 129 is an uncaught `try git.capture`, so it rethrows before the count closures are reached; the criterion was unsatisfiable. The working vector is `/usr/bin/false`, which launches and fails. (2) The `try!` mutation is unobservable for the same reason, so "confirm the suite crashes" asked for the impossible. (3) "Byte-identical stdout" is unachievable — envelope key order is nondeterministic per process, three distinct orders in six runs of the same binary. | `spec-defect` + `model-behaviour` |
| #0119 | 1 | The routing change is correct — `isPerWorktree` in one place with the right four namespaces, absent refs still `nil` on both branches. But the **suite is red**: `-q` is not a switch on `git tag` or `git update-ref`, so three fixtures throw before creating anything and the defect's end-to-end coverage never executes. One assertion (line 80) requires a shared ref to return `nil` — **the bug this issue removes** — and it *starts passing* under the mutation that restores the old behaviour. All three mutations are killed only by the pure-unit classifier; none by a test that calls `resolveRef` against a real repository. Plus an `EXPECTBANG` at line 42. | The round claimed *"all 261 tests pass, zero failures"* having never run `swift test` — its own log lists running it as the next move. **Second fabricated verification tonight** (after #0013 round 2). Rule 3 already forbids it, and the reviewer catches it by re-running, but one round late. `dispatch-issue.sh` now runs the suite itself after every round and writes the real `Test run with N tests` line into the round's own log, so the claim and the fact sit in the same artifact. | `model-behaviour` |
| #0121 | 1 | Count rose 272 → 276 and the suite went **red** — three tests fail in both ref formats. The intended fix is right and byte-exactly tested; removing the record trim broke oid parsing for every commit after the first. | **The trim was doing two jobs and the issue named one.** `git log` emits `<record>\n\0\n` — the `%B` newline, the `%x00`, then its own separator newline. Splitting on `\0` leaves every record after the first beginning with that separator, and `parts[0]`'s trim is `.whitespaces`, which does not absorb a newline. The old record-level trim stripped both the trailing `%B` newline (the bug) and the leading separator (load-bearing). Framing the issue as "one line at :151" is what hid the second job. The empty-tail test also concatenated records with **no** separator, so it never saw the byte that regressed — it passed while production was broken and survived the mutation. | `spec-defect` |
| #0116 | 1 | **Timed out at 1800s and the tree does not compile** — a botched edit left a stray `fieldCount` declaration trapping a doc comment inside an unterminated container literal. The half that matters is right: the new target imports `import YardGit` with **no `@testable`**, and `Package.swift` declares it correctly. | The model discovered every signature by compile error — `worktreeList(at:)` vs `(path:)`, `WorktreeListItem` vs `WorktreeEntry`, `result.description` vs `result.error?.description` — rewriting the test file **26 times** and running `swift test` **19 times**. Its own final notes list the corrections, so it had the answers at minute 29 and ran out of clock. **The issue named five entry points and gave none of their signatures.** It also shipped five assertions that cannot fail (`.count >= 0`, `x != nil \|\| x == nil`, `\|\| true`) which `check-tests-assert.sh` passed — now flagged as `ALWAYSTRUE`. | `spec-defect` |
| #0121 | 2 | **No code at all.** 3,028 output tokens, zero `write` or `edit` calls, exit 7 at the NO-CHANGES gate. | **A context compaction that fabricated its own history.** The summary claimed rounds 1–3, a round 4, and a list of test names that do not exist, and the model worked from it — importing round 1's `/tmp` sandbox incident into round 2 as a live instruction. The summary *contained the correct fix*; it discarded that, re-read `CommitLog.swift` a fourth time, and re-derived the diagnosis wrongly. The context pressure was self-inflicted: two full `swift test` runs piped into context before any work, plus a 470-line test file read whole — **and it never needed to run the suite**, because the issue already carried the `od -c` bytes and the failing test names. | `model-behaviour` |
| #0097 | 1 | Implementation **correct** — reads `standardError`, treats empty output as "nothing repaired", verified end to end against a real moved worktree. Suite red at 307/4-failing against a 295 baseline. | **A fixture path and the path git prints are different strings.** `NSTemporaryDirectory()` gives `/var/folders/…`; git reports `/private/var/folders/…`. The lookup `first(where: { $0.path == added.path })` was always nil, and a `try #require` on it aborted each test before the assertions it existed for — so those assertions could not evaluate true for **any** input. Fixed at the source: `FixtureRepository.url` now resolves through `realpath(3)`. Separately, one test asserted `reports.isEmpty` for repair-from-inside, which is the opposite of what git does, and it goes **green when the code breaks**. And the post-repair assertions sit behind the aborting `#require`, so mutation 2 could not kill them. | `spec-defect` (environment) |
| #0097 | 2 | Every test defect from round 1 fixed, and all three mutations now bite in the right place — mutation 2 kills a **post-repair porcelain** assertion rather than a count, which is what round 1 missed. Rejected on one failing test, and **that test is right**. | **My round-1 review was wrong.** It said the implementation was correct and must not change — true only because position 3 (the main repository itself moved) was never exercised. Round 2 added it, and git uses a **different message** in that case: `repair: .git file broken:` rather than `repair: gitdir incorrect:`, which the hardcoded prefix drops. Read from git's own source afterwards, `report_repair` emits `repair: <msg>: <path>` with exactly three `msg` values, so the fix is to parse structurally rather than widen a whitelist. **Covering the third invocation position is what found a real production defect** — the round-1 verdict was an artefact of incomplete coverage. | `review-defect` |
| #0097 | 3 | **The suite does not compile.** Round 3 removed the `try!` correctly but rewrote the line as `try #require` without marking the enclosing test `throws`. It also flattened the report — `"gitdir incorrect: /a/b/c"`, reason glued to path — so no caller could get the path `run()` is documented to return. | Two causes. `swift build` alone passes in 0.13s because it does not build test targets; the model ran exactly that, saw `Build complete!`, and stopped — `AGENTS.md` Rule 10, second round to hit it. And it was **denied `swift test` entirely**: OpenCode's sandbox rejected the worktree with a *corrupted path*, `brenbananMKE` where the command said `brennanMKE`, a string appearing once in round 3 and never in rounds 1–2. With no way to run the suite it had no feedback loop, which is the likeliest reason it accepted a library build as proof. Not the `/tmp` recurrence — scratch stayed in `build/`. | `environment` |
| — | — | **I accepted a change as verified when it only compiled.** `adba141` linked `YardKit` and `YardGit` into the app target. I proved it with a probe that imports both and touches a real symbol from each, plus a negative control, and reported "the app can now use the engine". **The app does not launch** — it dies in dyld on a Homebrew `libgit2` that is ad-hoc signed and so cannot be mapped into a Team-ID-signed process. | A dyld failure happens at **load** time. `xcodebuild build` succeeding says the symbols resolved at link time and nothing about whether the binary can start. For anything touching the app target, **launching it is the test**; compiling it is not. Filed as #0123. | `review-defect` |
| #0126 | 1 | Structure correct — `defaultIsolation`, one-way arrow, view moved, `project.pbxproj` correctly untouched. Rejected on the one criterion the target exists to enforce: the test used **`@testable import YardUI`**, which grants internal access and so cannot see the defect class the whole target was built for. Its own comment said importing without `@testable` is what a real app target does. | Dropping `@testable` immediately exposed a **second** defect it had masked: `ContentView` had a `public var body` and no `public init()`, and a public struct's memberwise initialiser is internal — the app could not have constructed it. Also recorded: the dependency-arrow mutation (`import YardUI` inside `YardGit`) **passes on an incremental build**, because SwiftPM resolves against a stale `YardUI.swiftmodule` in `.build`. Any layering assertion must `rm -rf .build` first or it proves nothing. | `model-behaviour` |
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

`scripts/check-tests-assert.sh` also gained a TAUTOLOGY scan for `#expect(true)` and friends, after
#0087 shipped a `testSuiteHasSufficientTests` whose entire body was `#expect(true)`. The INERT scan
could not see it: the body *does* contain an assertion macro.

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
10. **Has every code snippet in a Givens block been executed, in the context the model will run it
    in?** Not reasoned from something adjacent that was executed — run. A "Givens — verified" heading
    tells the model not to question the contents, so an unverified line there removes its licence to
    notice the error and it will spend the whole round forcing the wrong thing to work. #0093 lost a
    full 1800-second cap to one such line. If it has not been run, it belongs in Notes as a
    suggestion, where disagreement is allowed.
11. **Was every fact the issue asserts actually verified, by me, in this tree?** Not recalled, not
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
15. **Does a grep-based criterion actually match the shape it is looking for?** A quoted-literal
    search like `grep '"yard"'` misses interpolation (`"yard \(x)"`), concatenation, and multiline
    strings — it returns clean and proves nothing. Before writing a grep into a criterion, run it
    against a known-bad input and confirm it fires. This is the same failure as an inert test, one
    level up: the check ran, passed, and could not have failed.
16. **Does the assertion's predicate have any input that could make it true?** Distinct from the
    `[] == []` shape: here the comparison is over real data and still cannot fire, because
    `hasPrefix("YardKit")` is asked of a string that always begins `import `. No detector catches
    this — `check-tests-assert.sh` looks for missing assertion macros and `return`-shaped skips, not
    predicates that are structurally unsatisfiable. **The only reliable test is mutation**: break the
    thing the assertion guards and confirm it fails.
17. **If the deliverable is prose — a comment, a doc, a message — has someone read every new
    sentence against the code?** No mechanical check can. #0111 passed every guard in the harness and
    still landed three fabricated claims, because the tests do not read English. When asking for
    documentation, require that each sentence name something visible in the code, and say explicitly
    that elaboration is not wanted: **a doc comment may not contain a claim that would need a test to
    be true.**
17. **When a review names a defect, does it name the CLASS or one instance?** A review saying "fix
    X in test Y" reliably gets X fixed in Y and nowhere else. #0020 round 3 added the required
    `#require` guard to the single test the review named by title and left the identical unguarded
    subscript at seven other sites — where a mutation then trapped and destroyed the run. If the
    defect is a pattern, say so, and give the command that finds every occurrence.
17. **Does the issue name the existing affordance, not just the constraint?** #0112 said "merging an
    ancestor is a no-op, you need divergent commits" and did not mention that
    `FixtureRepository.conflicted()` already builds precisely that state. The round reconstructed it
    badly. Stating a requirement invites reinvention; **naming the helper that satisfies it does not**.
    Before writing "you will need X", grep for whether X already exists.
18. **Before creating `issues/NNNN.md`, is NNNN actually free?** Pick the number with
    `ls issues/[0-9]*.md | sed 's/.*\///;s/\.md//' | sort -n | tail -1`, over **every** file, not
    over the open ones — a resolved issue still owns its number. Create it with a tool that fails on
    an existing path, never a `>` redirect. I clobbered resolved issue #0113 this way and only
    noticed because the workflow log happened to mention it by number.
19. **Does the assertion distinguish the right state from a neighbouring wrong one?** Not just "can
    it fail" — *what else makes it pass*. `CHERRY_PICK_HEAD exists` is true for a conflicting
    cherry-pick **and** for an empty one; #0112 round 2 shipped the second while claiming the first.
    For any marker-file check, name a second observable that differs between the two states — here,
    unmerged index entries, 3 versus 0 — and assert on that instead.
20. **Has the code the issue is about actually been run, on the input the issue is about?** Not
    read — run. #0013's re-authoring fed real porcelain v2 bytes to the parser on `main` and found
    three defects its own tests cannot see: renames silently dropped by an off-by-one, a single
    non-UTF-8 byte erasing the entire status, and submodule state flattened. A throwaway test in the
    existing target, deleted immediately, costs four minutes and turns a feature request into a
    repair with a measured before-count. See workflow log §5.3.
21. **If the tests have privileges the caller does not, is the boundary checked at the caller's
    level?** `@testable import` grants internal access, so a `public` API whose members are internal
    passes every test and is unusable from outside — #0116, found by compiling a probe package
    against the product. Anywhere the harness has a capability the caller lacks, that boundary needs
    a check compiled the way a caller compiles. See workflow log §5.4.
22. **If the issue says a behaviour is "the default", does it name the function that has a default?**
    #0096 said reporting is the default and pruning is opt-in, and named only the output file. The
    round produced two unrelated static functions with nothing choosing between them — a default
    needs a parameter, and a parameter needs a signature. Write the signature into the issue.
23. **When a mutation dies, does the *right* test kill it?** #0088's `exitCodes = []` mutation
    failed the suite — through a `--help` rendering test that greps text for "Exit codes", not
    through the registry test the criterion asked for. The same mutation on the second spec passed
    silently, because that spec is never rendered. **Record which test failed, not just that one
    did**; a mutation killed by an unrelated test is evidence of coverage you do not have.
24. **Verify the branch at the END of a round, not just the start.** `dispatch-issue.sh` checks
    `git rev-parse --abbrev-ref HEAD` before dispatching and cannot see a mid-round switch. #0088
    round 1 came back on `issues/0088` — plural — a branch it created itself, against `AGENTS.md`
    Rule 4.
25. **Is an empty grep being read as "inconclusive"?** It is a result. #0096 round 2 grepped
    `swift test` output for `Test run|passed|failed`, got nothing because the suite did not compile,
    and treated that as needing further investigation rather than as the answer. When a command's
    output is expected to contain a specific line, its **absence is the finding** — say so and stop,
    do not go looking for a better view of it.
26. **Does the issue give the fixture's *mechanism*, not just its shape?** #0096 listed four
    worktrees in a table and never said that **git marks only an *unlocked* worktree prunable** — so
    deleting the unlocked one is the only thing in the fixture that produces a `.prunable` report.
    The round deleted the two locked ones instead, every assertion failed unmutated, and it read that
    as an engine bug. A table says what to build; only the mechanism says what breaks if you build it
    slightly wrong.
27. **Is "write tests" a checkbox in Expected behavior, naming the file?** A "Tests must be able to
    fail" section reads as advice on *how* to test, not as a deliverable. #0013 round 2 changed only
    the source, left the count at the branch baseline, and reported success. Put
    **"`<path>/FooTests.swift` gains tests; `git diff --name-only` lists two files"** in Expected
    behavior, where the round reads what it owes.
28. **Is there anything left for the model to go and find?** #0120 round 1 spent its only productive
    2.5 minutes handing discovery to an `@explore` subagent and then hung on the handoff. That
    subagent appears in three of the four most recent failed rounds. If the issue names every type,
    signature and path inline, there is nothing to explore and nothing to hang on.
29. **Did you measure the part, then assert the composite?** #0114 verified that `GitProcess` throws
    on an unlaunchable path — true — and then wrote a criterion about what `whereAmI` returns when
    given one, without running that. `whereAmI` rethrows before it reaches the code the criterion is
    about, so the criterion was unsatisfiable by any input. **Run the composite.** This is #0093's
    failure with different nouns, and it has now cost two rounds.
30. **If you are removing a line, does it have more than one job?** #0121 removed a
    `trimmingCharacters` call to stop it eating `%B`'s trailing newline. The same call was also
    stripping the record separator `git log` writes between entries, and nothing else did — so the
    fix broke oid parsing for every commit after the first. **Before specifying a deletion, ask what
    else that line is the only thing doing.** A one-line framing invites a one-line answer.
31. **If the round must CALL an API, does the issue paste its signature?** #0116 named five public
    entry points and gave none of their signatures; the round found each by compile error, rewrote its
    test file 26 times, and hit the wall clock with the answers in hand. Naming a function is not
    enough when the round has to write a call to it — **paste the declaration, and the members of its
    result type.**
32. **Has the round been told not to run the suite before it writes anything?** #0121 round 2 piped
    two full `swift test` runs into its context before doing any work, compacted, and then worked from
    a summary that had invented four prior rounds and a set of test names that do not exist. When the
    issue already carries the measured failure, say so and say not to re-measure it.
33. **Does the test compare a fixture path against a path git printed?** They are different strings.
    `NSTemporaryDirectory()` gives `/var/folders/…`; git always reports the resolved
    `/private/var/folders/…`. #0097 round 1 lost every one of its assertions to a `try #require` on a
    lookup that could not succeed. `FixtureRepository.url` is now resolved at construction with
    `realpath(3)` — and note that `resolvingSymlinksInPath()` does **not** do this, it strips a
    leading `/private` instead.
34. **Did the round exercise every case the issue lists, or only the ones that were easy?** #0097
    round 1 covered two of three invocation positions, did not say so, and I accepted "the
    implementation is correct" on that basis. Round 2 added the third and it failed immediately —
    git emits a different message when the main repository moves. **An uncovered case is not a
    passing case**, and a verdict formed without it is provisional.
35. **For an app-target change, does the criterion say "it launches" rather than "it builds"? And is
    the build SIGNED the way the failure needs?** Linking, embedding, entitlements, `Info.plist` keys
    and dylib loading all fail at **launch**, not at compile — I accepted `adba141` on a
    compile-and-link probe and the app died in dyld the first time it ran. But #0123 then showed the
    corrected criterion is still not sufficient: an **unsigned** build is ad-hoc signed, and an ad-hoc
    process can map an ad-hoc dylib, so the broken tree launches too. For a Team-ID mismatch the
    evidence is the **absent load command** (`otool -L`), not the launch.
    Linking, embedding, entitlements, `Info.plist` keys and dylib loading all fail at **launch**, not
    at compile. `xcodebuild build` succeeding proves the symbols resolved and nothing else. I accepted
    `adba141` on a compile-and-link probe and the app died in dyld the first time it was run.
36. **Does a dependency-direction check run on a CLEAN build?** #0126's mutation — adding
    `import YardUI` inside `Sources/YardGit` — **succeeded** incrementally, because SwiftPM resolved
    it against a stale `YardUI.swiftmodule` left in `.build`. `rm -rf .build` first, or the assertion
    that the arrow points one way is worthless.
37. **Does the issue name the collaborators, not just the output file?** "Name the file" fixed
    convergence months of rounds ago, and it is necessary but not sufficient: a file name says where
    code goes and nothing about what it may call. If the work must use an existing type, **quote its
    real surface in the issue** — #0012 lost a full 30-minute cap to a model inventing
    `GitProcess.GitRunner` and `Platform` because nothing told it `GitProcess` is a concrete struct
    with no injection seam. Say explicitly when there is no protocol to implement; a model reaching
    for testability will invent one.
17. **If the branch changed since the `## Review` was written, does the review still describe the
    tree the model will see?** A review is written against the state at the end of a failing round.
    Any merge, rebase or correction after that can silently invalidate it — and it will still *read*
    as current instruction, because prose carries no timestamp. This cost #0102 a round: a merge
    reverted the previous round's documentation work, the review did not mention documentation
    because it had been done, and the model correctly treated the review as the task. **Re-read the
    review against the actual tree immediately before dispatching**, not when writing it.
17. **Does the criterion assert the content, or only that something was produced?** "Prints the
    version envelope" is satisfied by an envelope containing the wrong string. Name the expected
    content: *the `result` must begin with `switchyard`*.
17. **Does any test extract or filter before asserting, without checking the extraction is
    non-empty?** This is the inert-test shape that has an `#expect` and still proves nothing — a
    helper returns `[]`, and the comparison becomes `[] == []`. It is invisible to the detector and
    to a reading of the test's name. Whenever a test parses, scans, or filters, look for
    `#expect(!x.isEmpty)` before the real assertion; if it is missing, run the helper yourself
    against real input and see what it returns.
16. **Do the new tests actually assert?** The recurring inert-test pattern: a loop over `allCases`
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

## If a round produced no diff, write its `## Review` section in the same turn

`dispatch-issue.sh` refuses any round after the first unless the issue has a `^## Review` heading. That
is right — re-dispatching an unchanged prompt re-runs a prompt already proven not to work. But a round
killed at the timeout with an empty tree has **no diff to review**, so the heading is easy to skip, and
the next dispatch then bounces two seconds in.

This has now happened twice, to #0013 and #0120. Both times a dispatcher subagent hit the guard,
correctly refused to route around it, and stopped — costing a full round-trip each time.

**"Nothing to review" is itself the review.** Under the heading, say what the round did before it
died, and what has changed since so this one will not repeat it. Write it in the same turn as the
failure row and the cost-ledger entry, for the same reason those are written immediately: the turn
that has the facts is the turn that should record them.

## The guards have fired — what they caught, after being written

Recorded because a guard nobody can point to a catch for is superstition, and should be deleted.

| Guard | Caught |
|---|---|
| Branch-dependency check (5) | **#0092**, which said "Start from `issue/0011`" — the exact defect that cost #0090 a full 1289s round. Rejected before dispatch, at no cost. |
| Names-a-source-file check (3) | **#0092** and **#0093**, both of which named none. Every code round that has ever failed named zero paths. |
| Verification-command check (4) | **41 open issues**, including #0012–#0020, which claimed coverage in prose ("tested against both ref formats") with no command whose output could be pasted. |
| Baseline-count check (9) | Every issue authored before #0086 — a bare "prints `Test run with N tests`" is satisfiable by a round that adds nothing to the run. |
| Executable-target check (1) | **#0026, #0086, #0087, #0088**, all queued behind #0085 with the identical unbuildable path. |
| Negative controls on the guards themselves | Two guards that would have blocked *every* dispatch — one killing the script on any healthy issue under `ERR_EXIT`, one rejecting #0085 for quoting its own post-mortem. Both caught before being wired in. |

The pattern worth noting: **most of these were already-written rules that nothing enforced.**
"Name the file" was in `issues/Issues.md` before #0090 was authored in violation of it. The rule was
not the fix; the check was.

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
