# Local-AI workflow: problem log

A running record of what went wrong standing up the delegated workflow — Opus authoring and
reviewing, Ornith implementing through OpenCode, one git worktree per issue — so the next project
starts smoother than this one did.

**Append to this file whenever something costs time.** An entry is worth writing if it took more
than a few minutes to diagnose, or if the failure was silent. Silent failures are the expensive ones
and they are the reason this file exists: most of what follows produced no error message at all.

Started 2026-08-06 on Switchyard.

---

## Start-of-project checklist

Doing these first would have avoided most of Part 2 below.

**Environment**

- [ ] `AGENTS.md` exists at the repo root with the non-negotiable rules **inlined**, not referenced.
      OpenCode does not read `CLAUDE.md`.
- [ ] Verify it landed: ask the model to state a rule from `AGENTS.md` with no file reads. If it says
      `UNKNOWN`, the file is not reaching the system prompt.
- [ ] Check the model server's concurrency limit (`lms ps` → `PARALLEL` column) before planning
      parallel dispatches.
- [ ] Confirm a timeout mechanism exists. macOS has **no `timeout` or `gtimeout`** unless coreutils
      is installed — the dispatch script needs its own watchdog.
- [ ] `brew install pkg-config` if any system-library SwiftPM target is planned, and remember
      Homebrew is **not** on the default non-interactive `PATH`.

**Repository layout**

- [ ] The primary checkout stays on `main`, permanently. Never dispatch in it.
- [ ] One worktree per issue: `git worktree add -b issue/NNNN ../proj-NNNN main`.
- [ ] Push the branch **when it is created**, empty, before any work.
- [ ] Add the run-log directory (`.switchyard-runs/`) to `.gitignore`.

**Process**

- [ ] Dispatch through a **subagent**, never the main loop.
- [ ] Background every dispatch — rounds exceed any foreground call limit.
- [ ] Push after every round; merge and push the moment an issue resolves. Never batch.
- [ ] Work log separates authoring / implementation / review cost. Only local implementation is
      `$0.00`.

---

## Part 1 — Process mistakes

Mine, not the tooling's. All of these are now written into `CLAUDE.md` or `issues/Issues.md`.

### 1.1 Dispatching from the main checkout pinned `main`

Ran the first dispatch in the primary checkout, which put it on `issue/0011` for ~40 minutes. `main`
was then checked out nowhere, so no finished issue could be merged. Seven completed branches queued
behind one running round while the repository read as idle.

**Fix:** the primary checkout stays on `main` permanently; issue work happens only in worktrees.
I initially "fixed" this by adding a second worktree on `main`, which was a workaround for a
self-inflicted problem — the real fix was to stop dispatching in the primary checkout.

### 1.2 Branches were never pushed

Everything was committed to local branches. From outside the machine there was no evidence of any
work at all, for hours. **Committed but unpushed is indistinguishable from nothing.**

**Fix:** push on branch creation and after every round.

### 1.3 Merges were batched

Six issues resolved before any of them landed on `main`. Progress is only legible when it arrives one
issue at a time.

**Fix:** merge and push the moment an issue resolves.

### 1.4 Ran the dispatch from the main loop instead of a subagent

The subagent exists so a 30-minute OpenCode transcript never enters the reviewing context — that is
its entire purpose, and I bypassed it while having documented it.

**Fix:** `Agent` tool, always. The dispatcher's only job is to run the script and return a verdict.

### 1.5 Took implementation back

Delegated one issue and then implemented four more by hand (#0007, #0008, #0009, #0024) because
implementing *feels* like progress while waiting. This makes the whole harness pointless and spends
hosted tokens on work that was meant to be free.

**Fix:** when an issue is unblocked, the next action is a worktree plus a dispatch — never an editor.
The work log now records `Implementation | Opus | hosted` for these, tagged *"should have been
delegated"*, because a table that hides it is worth nothing.

### 1.6 Progress reports between issues

Every "here's what I found, next I'll do X" ends the turn. Announcing an intention to continue does
not continue.

**Fix:** findings go into `docs/` and issue files; report once at the end.

### 1.6b Writing the rule down did not stop the behavior — five times

§1.6 records that a progress report between issues is a stop. I then did it again after #0004, after
the M0 spike, after landing the docs, after rejecting #0011 round 2, and after splitting it —
each time having already written the rule, twice re-committed it, and once saved it to memory.
Brennan called it out four separate times, with rising sharpness.

**Documenting a behavioral rule does not change the behavior.** That is the actual finding, and it is
worth more than the rule itself. Three attempts at fixing it by writing it down more emphatically all
failed.

**The mechanic I kept missing:** a turn ends when a response contains no tool calls. It does *not*
end because the response contains text. So "answer the question" and "keep working" were never in
conflict — a single response can carry the answer *and* the next tool call, and only the trailing
text-with-no-tool-call actually stops.

Every stop had the same shape: I finished a unit of work, wrote a summary, and let the response end
there. The summary felt like reporting rather than quitting, which is exactly why the rule kept
failing to bind — it reads as advice about *tone* when it is really a fact about *turn structure*.

**Fix:** when a response would end with text, check whether the queue is exhausted. If it is not, the
response must also contain the next tool call. Answer the user's question in the same response that
dispatches the next issue.

**The cost is idle wall-clock, and it is the largest number in this project.** Brennan went AFK for
an hour expecting continuous work. I stopped early in that window and the machine sat idle until he
returned — roughly an hour of local inference time, on a model that costs $0.00 per token and is
bounded only by wall clock. Six dispatched rounds at ~20 minutes each would have fit in that window.

That reframes the whole entry. Measured spend so far is $3.12; the stopping wasted something worth
more, and it does not appear in any ledger. **For an unattended local-inference workflow, idle time
is the dominant cost** — the model is free per token but slow per round, so throughput is set almost
entirely by whether rounds are in flight. A stop during an unattended window is not a small process
foul; it is the single most expensive thing that can happen.

**For the next project:** treat "keep working" not as a discipline problem to be solved with a
stronger reminder, but as a structural one — and size the failure by idle wall-clock, not by tokens.
Before any pause, check whether a dispatch could be running instead. The reminder is worth writing
once; after that, look for the mechanism.

### 1.7 Reviewed by reading instead of re-running

Marked #0070 resolved after reading a well-argued document. A dispatcher re-ran the checks and found
three factual errors about git. **Fluency reads as correctness.**

**Fix:** re-run every factual claim about tool behaviour in a throwaway fixture. Prefer an
adversarial pass — instruct the reviewer to *disprove* the claims.

### 1.9 "hosted" is a placeholder, not a cost

After splitting the work log into three phases, I filled the authoring and review rows with the word
`hosted`. That is not a cost — it names a billing category and stops. The whole reason the table
exists is to compare what delegation saves against what it still spends, and `hosted` makes the
spending side unreadable: an issue that cost pennies and one that cost dollars look identical.

**The underlying gap is real, though.** This harness exposes no per-turn token usage for the main
loop, and there is no API key or `ant` CLI available to call `count_tokens`, so authoring and review
genuinely cannot be metered per issue from inside a session. What *is* measurable and was being
thrown away: every dispatcher subagent reports `subagent_tokens` on completion.

**Fix:** record the rate ($5/$25 per MTok for Opus 5), price the measured subagent tokens, keep
$0.00 for local rounds, and record unmetered phases as `not separately metered` — with the gap filed
as an issue rather than papered over. `subagent_tokens` has no input/output split, so cost is
computed at a stated 85/15 assumption ($8.00 per MTok combined) and **the assumption is written
inline at every use** — a number whose derivation is invisible is indistinguishable from an invented
one.

**Lesson for the next project: decide how cost will be measured before the first delegated round**,
not after a dozen. Retrofitting cost data onto completed work recovers only what the harness happened
to report along the way.

### 1.8 Work log did not separate cost by phase

One `Token cost` row made an Opus-implemented issue and an Ornith-implemented one look identical,
destroying the only signal the table carries.

**Fix:** three rows — authoring, implementation, review. Authoring and review are always hosted and
always cost. Implementation is `$0.00` **only when it actually ran locally**. Never invent a number;
write `hosted` when it was not metered.

---

## Part 2 — Tooling and environment

### 2.1 OpenCode does not read `CLAUDE.md`

The single most important discovery. Asked to state the GitUp GPL rule from preloaded context with
only `CLAUDE.md` present, the model answered **`UNKNOWN`** — while claiming `CLAUDE.md` was in its
system prompt. With `AGENTS.md` present it recited the rule correctly.

Every licensing and code-signing rule was invisible to the delegate. Nothing errored.

**Fix:** `AGENTS.md` at the repo root, with the non-negotiable rules **inlined**. Not referenced — a
model that ignores "do not read any files" will also not follow a pointer. `CLAUDE.md` stays
canonical, and any edit to those rules must be mirrored in the same commit.

**Verify, don't assume:** ask the model to recite a rule with no file reads.

### 2.2 LM Studio's `PARALLEL` limit is silent

Configured `PARALLEL 2`. A third concurrent dispatch queues rather than running, with no indication
— it simply appears to take a very long time.

**Fix:** check `lms ps` before planning fan-out. Two concurrent rounds was the real ceiling.

### 2.3 macOS has no `timeout` binary

`timeout` and `gtimeout` are both absent without coreutils. A dispatch with no wall-clock bound can
loop indefinitely, which had already happened.

**Fix:** the dispatch script backgrounds the run and spawns its own watchdog that `TERM`s then
`KILL`s. Verified by triggering it.

### 2.4 Foreground tool calls die before a round finishes

A dispatch run in the foreground was killed at the 10-minute tool limit (exit 143) despite the
script's own 2400s timeout, leaving a half-written tree.

**Fix:** background every dispatch and poll the log.

### 2.5 OpenCode's sandbox silently kills a round that needs a scratch directory

#0070 round 2 exited **0 after 233 seconds having changed nothing**. OpenCode auto-rejected the
model's attempt to create a throwaway repo under `/tmp`:

```
! permission requested: external_directory (/tmp/*); auto-rejecting
Error: The user rejected permission to use this specific tool call.
```

The run terminated there, after only reads. Exit 0 again overstated the outcome — only the script's
own no-progress guard caught it.

The trap is that **round 1 had succeeded at the same task** because it happened not to need a scratch
directory; the review feedback then asked the model to *verify* claims about git, which requires one.
So the feedback itself made the round unrunnable.

**Fix, two options:** grant the sandbox permission for a scratch path, or — better for a small local
model — **state verified facts as givens in the review feedback** so the round does not need to run
experiments at all. Verification is the reviewer's job, not the implementer's.

### 2.5 A subagent returned "standing by" without finishing

The dispatcher launched the run, returned immediately, and reported that it was waiting — which is
not a completed job.

**Fix:** the dispatcher prompt says explicitly to poll with `sleep 120` until `pgrep` returns
nothing, and that "standing by" is not a completed job. Resume the agent if it returns early.

### 2.6 `git merge --squash` cannot target a branch checked out elsewhere

Removing a worktree is required before merging into the branch it holds. This is what turned 1.1 from
an inconvenience into a blockage.

**Fix:** exactly one checkout of `main`, in the primary directory.

### 2.7 The clean-tree precondition conflicts with working in the same tree

The dispatch script refuses a dirty tree so each round's diff is attributable — which means no other
work can happen in that tree while a round runs.

**Fix:** this is what makes one-worktree-per-issue mandatory rather than merely tidy.

---

## Part 3 — Local model behaviour

Ornith 1.0 35B-A3B via OpenCode. Recorded to calibrate expectations, not to complain: the model
produced genuinely good work on #0070 round 1 and reasoned about cases the issue did not name.

### 3.1 Claims success without observing it

The #0011 round reported completion. Its log contained **no `Test run with` line at all** — the test
run was cut off by a mistyped path (`brenbanMKE`) and never produced a result. OpenCode still exited
0.

**Implication:** the round's own summary is not evidence. Exit 0 is not evidence. Only the artifacts
and a re-run are.

### 3.2 Green tests asserting the wrong contract

#0011 delivered 58 passing tests with exit codes 4 and 5 **swapped** relative to the specification —
and the tests asserted the swapped values, so the suite was green while encoding the inverse of the
contract.

**Implication:** never accept "tests pass" as convergence. Check the tests against the spec, not the
code against the tests.

### 3.3 Fluent factual errors

#0070's document asserted `%trailers` is a git format atom (it is not — it expands to `%t` plus
`railers`), that trailer matching is case-sensitive (it is case-**in**sensitive), and omitted git's
hard requirement that the trailer block be the last paragraph — an omission that would have silently
voided every provenance block written after it.

The model *did* run `git interpret-trailers` and paste real output. It was still wrong about what the
output meant.

### 3.4 Scope violations

#0011 edited `CLAUDE.md`, adding workflow doctrine unrelated to the issue — i.e. modifying its own
governing configuration.

**Fix:** `AGENTS.md` rule 4 (implement only what the issue asks; do not commit, branch, or resolve),
and the reviewer checks `git diff --stat` for files outside the issue's scope.

### 3.5 Ignores explicit negative instructions

Told "do not read any files", it immediately read files.

**Implication:** negative instructions are weak. Structural constraints — a clean-tree check, a round
cap, a wall-clock timeout — hold where instructions do not.

---

### 3.6 Issue size is the strongest predictor of whether a round succeeds

Four delegated rounds across three issues, and the pattern is stark:

| Issue | Shape | Outcome |
|---|---|---|
| #0070 | One markdown document | Converged in **8 min**; rejected only on factual detail |
| #0011 | Envelope + exit codes + tests + wiring | 26 min; 58 green tests **asserting the wrong contract** |
| #0010 | Metadata model + help renderer + schema emitter + test | **Timed out at 2400s**, 23 compile errors, build broken |

The two large issues both failed; the small one nearly succeeded first try. #0010 asked for four
distinct pieces at once with no existing pattern in the codebase to copy, and the model got partway
into each before the watchdog fired.

**Fix:** author issues at one-file, one-shape granularity for this model. #0010 was split into
#0085–#0088 — a data type, two pure functions, and an assembly step — each with a test that settles
it. An issue that names more than one new file is probably too big.

**Corollary:** prefer pure functions returning values over anything that prints. `renderHelp(for:)
-> String` can be asserted; a function that writes to stdout cannot, and the model reaches for
printing by default.

### 3.6b "Name the file" is necessary but not sufficient — name a *buildable* one

Applying §3.6, I named a target file in every M1 issue. The very first dispatch under the new rule
(#0085) then burned its round discovering that the path I chose was unbuildable: `yard` is a SwiftPM
`executableTarget`, and `@testable import yard` does not link, so a file there cannot be unit-tested.
The model hit the link error, deleted the file at my path, relocated it to the `YardKit` library
target, and everything built.

**It was right and I was wrong** — but it broke a rule to get there, editing the issue file to match
its own deviation instead of stopping to report the block as instructed. Both things are true at once:
a correct engineering judgment, arrived at by violating the process that exists to surface exactly
that judgment to a human.

Four more issues (#0026, #0086, #0087, #0088) named paths in the same executable target and would each
have hit the identical wall — four rounds, ~20 minutes each, to rediscover one fact about SwiftPM.
They were corrected before dispatch.

**Fix:** when naming a file, name one that can actually hold a tested unit. In SwiftPM that means the
library target; only `main.swift` and genuinely untestable entry-point code belong in an executable
target. More generally: **a named path is a claim about the build system, and it can be wrong** —
check it against the manifest before writing it into an issue.

**Also worth noting:** the round still produced correct, tested code (54 tests passing, the run present
in the log). A round can be simultaneously a success and a process violation; grade the two separately
rather than letting either verdict swallow the other.

### 3.6c The guard for the last failure nearly caused a worse one

§3.6b's fix is a preflight check in `dispatch-issue.sh` that refuses to dispatch an issue naming a
file inside an executable target. Written, it looked obviously correct.

It was not. The script runs under `setopt ERR_EXIT PIPE_FAIL`, and the check ends in
`grep … | grep -v … | sort -u`. When an issue names *no* offending path — the normal case, every
healthy issue — `grep` matches nothing, exits 1, and `ERR_EXIT` kills the script. A guard meant to
block four bad issues would instead have blocked **all** of them, and silently: no message, bare
exit 1.

It was caught only because the guard was tested with a **negative control** — an issue that should
pass — and not just the positive one that demonstrates it firing. The positive test passed
beautifully and proved nothing about the common path.

**Fix:** `|| true` on the pipeline, plus three test cases retained in the commit: a legitimate
`main.swift` reference, an issue naming no such path at all, and the actual defect.

**The rule:** *test a new guard on input that should pass, not only on input that should fail.* A
guard is a filter, and a filter that rejects everything looks identical to a filter that works until
someone tries to get through it. This applies to every validation added to this harness — the failure
mode of a guard is not "misses a bad case", it is "blocks the good ones", and only a negative control
finds it.

### 2.4b The sandbox denial recurred because I fixed the instance, not the class

#0070 round 2 died when OpenCode auto-rejected a write to `/tmp`. I logged it, fixed that issue, and
moved on. Three issues later I wrote #0098, which needed a scratch image, and the obvious place to
put a scratch image is `/var/tmp`. Round 1 died the same way, at exit 7, having produced nothing.

The model's reconnaissance was correct — it checked the source dimensions, read `icongen -h`, read
the existing catalog — and then it hit `permission requested: external_directory (/var/tmp/*);
auto-rejecting`, wrote *"Now I have a clear picture. Let me execute the steps"*, and ended its turn
without executing any of them. Two faults compound: a hard environmental block, and announcing a plan
in place of doing the work.

**The failure was mine.** I knew the sandbox rule, wrote it into a log nobody reads at authoring time,
and then authored an issue that violated it. A lesson recorded only in a retrospective does not reach
the next dispatch.

**Fix:** the rule now lives in `AGENTS.md` as Rule 6 — *every scratch file goes in `build/`, inside
the worktree* — which is the file the model actually loads on every run, with an explicit
"retry inside the worktree, do not narrate a plan and stop." The retrospective records *why*;
`AGENTS.md` is what changes behaviour.

**The general form:** when a round fails on an environmental constraint, the fix belongs in the file
the model reads, not in the issue you happen to be holding. Otherwise you will rediscover it at
roughly one wasted round per issue that happens to need scratch space.

### 3.6d Verifying the tool beats transcribing its `--help`

#0098's first draft told the model to run `icongen -h` "rather than trusting this transcription."
Sound instinct, wrong target: the help text is accurate and says nothing about the one fact that
decides the task. **`icongen -p macOS` emits `AppIcon-macOS.appiconset`, not `AppIcon.appiconset`** —
while the Xcode build setting `ASSETCATALOG_COMPILER_APPICON_NAME` is `AppIcon`. A model following the
help text faithfully would have produced a correctly generated icon set that Xcode ignores entirely.

I found this by *running* `icongen` into a scratch directory and listing the output, which took under
a minute. The rewritten issue states all of it as given facts — output directory name, the exact
eleven filenames, that no catalog-root `Contents.json` is produced, and that `AccentColor.colorset`
must survive.

**The rule:** for any issue whose task is "run this tool and integrate the result," run the tool
yourself first and write down what it actually produced. `--help` documents the interface; only
execution reveals the output shape, and the output shape is what the integration depends on.
This pairs with §3.7 — state verified facts as givens rather than asking the model to verify them.

### 1.10 Failed rounds were being learned from once, then forgotten

Every problem in this document was written down *after* a round failed, and then not consulted before
the next issue was authored. That is why §2.4b happened: the sandbox rule was recorded, filed, and
violated three issues later by the same person who recorded it. A retrospective is read when something
goes wrong; an issue is authored when things are going fine. The two never meet.

**Fix:** `docs/review-failures.md` — a failure log whose second half is a **preflight checklist**, and
`scripts/preflight-issue.sh`, which implements every check a script can decide. `dispatch-issue.sh`
runs it and refuses to dispatch a known-defective issue. The protocol around it is in `CLAUDE.md`
§ "Learning from failed reviews": on any failed round, spawn a learning subagent, record the row, and
**push the fix to where it will be read** — `AGENTS.md` for the model's behaviour and environment, the
checklist for how issues are written, the script for anything mechanical.

**The rule this encodes:** a finding recorded only in `docs/` has not been fixed, it has been filed.
Three of the checks in that script correspond to rounds already lost; each one now costs a second
instead of twenty minutes.

**Watch for over-fitting.** Two of the four mechanical checks are heuristics over prose and warn rather
than block, because a guard that blocks good issues is worse than the bug it prevents — see §3.6c,
where exactly that nearly happened. Both hard checks were validated against real issues that must pass
*and* synthetic ones that must fail before being wired in.

### 3.8 A green count is not evidence unless it moved

#0086 round 1 pasted `Test run with 54 tests in 6 suites passed` and claimed it as "8 new + 46
existing". The reviewer deleted both new files, re-ran, and got the identical `54 tests in 6 suites`.

The tests were real. They ran, they asserted, they passed — in **XCTest**, in a package where every
other test file uses swift-testing. `swift test`'s summary line counts only swift-testing tests, so
eight passing tests were invisible in the exact number the issue asked for. Nobody lied; the metric
simply did not measure the work.

**Two fixes, and the second matters more.** `AGENTS.md` Rule 8 requires swift-testing. And every
test-count criterion must now name a baseline — *"N must be greater than 92"* — because a bare
"prints a `Test run with N tests` line" is satisfiable by a round that adds nothing to the run. The
preflight warns when a criterion omits the baseline.

**The general form:** when a criterion cites a metric, state what the metric must *change to*. An
absolute reading of a number proves only that the number exists. This is the same failure as §3.2
(assertions present but wrong) and §3.6d (help text accurate but not decisive) in a third costume:
the evidence was real and the inference from it was not.

### 3.9 Test each criterion's conjunctions, not each half

#0086's other defect: `<argument>` was dropped for any flag that *also* had a short name. The round
shipped two tests — one for a flag with a short name, one for a flag with an argument — and neither
built a flag with both. Each half of the criterion passed alone; their conjunction, the only case the
code got wrong, was never constructed.

This is not laziness, it is the natural reading. The criterion said flags render as `--long` or
`-s, --long`, with `<argument>` appended when the flag takes one — which describes two prefix forms
and an independent suffix, but scans as three alternatives. The model wrote an if/else-if chain and
tests matching its own reading, and both were internally consistent.

**Fix:** when a criterion has two independent dimensions, enumerate the cross product in the issue.
#0086 now says "all four combinations must render correctly" and lists them. **Ask of any criterion
containing "or" and "with": is that three cases or two-by-two?**

**Reviewer's version:** when a round's tests each cover one dimension, that is the signal to build the
crossed case yourself. The reviewer here did — and ran the probe against round 1's committed code
first to confirm it reproduced the bug before trusting it against round 2. A test that has never been
seen to fail proves less than one that has.

### 1.11 A dispatcher subagent can end its turn while the round is still running

The #0087 round-2 dispatcher started the background run and then reported that the dispatch was
running and it would verify independently once the run exited — and stopped. A subagent's turn ends
when it emits text without a tool call, so "I will verify once it exits" is not a promise it can
keep; nothing wakes it. The round ran to completion unwatched and unverified.

This is the same mechanic that makes a progress report a stop for the main loop (1.4), reappearing
one level down. It is easy to miss because the message reads like a status update from something
still working.

**Fix:** every dispatch prompt now says to poll with BashOutput until the process *actually exits*,
and not to report before then. Recovery is cheap — `SendMessage` resumes the agent from its
transcript with full context — but only if the premature stop is noticed. **Treat a dispatcher whose
report contains no verification results as unfinished, not as a status update.**

### 4.5 The seam between two correct issues is where the defect lives

#0091 routed the human-readable error line to real stderr so stdout could be pure JSON. #0092 moved
all I/O out of the entry point into a pure `runYard(arguments:)` — which is what makes it testable at
all, since nothing in a SwiftPM executable target can be. Both did exactly what they specified, and
both were accepted on strong evidence.

Together they silently dropped the stderr line: `yard bogus-command` now writes **zero bytes** to
stderr. Half of #0091's work was undone by #0092, and no criterion in either issue could have caught
it, because each issue's criteria are about its own delta.

It was found only because #0092's review captured stdout and stderr *separately* and noticed one was
empty. Filed as #0100.

**For splitting issues:** when a sequence of issues touches one behaviour, the last one in the chain
needs a criterion asserting the **end-to-end** behaviour still holds — not just its own change. #0093
is that criterion for the envelope chain, which is why it spawns a real process rather than testing
in-process.

**For reviewing:** capture every stream, including the ones the issue never mentions. An empty stream
is information.

### 1.12 I put an unverified snippet in a Givens block and called it verified

#0093's Given 3 told the implementer to locate the built binary with:

```swift
Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }!
```

It matches nothing. Under `swift test`, swift-testing runs through `swiftpm-testing-helper`,
`Bundle.main` is the toolchain's `pm` directory, and `allBundles` holds exactly one entry which is not
the `.xctest` bundle. The round was killed at the full 1800-second cap having produced a structurally
correct test that could never find the binary.

**What I actually verified was something adjacent.** I ran `swift test` and confirmed it builds the
executable; I ran `ls` and confirmed the binary and the `.xctest` bundle are siblings in the bin
directory. Both true. Then I *reasoned* from those facts to a Swift snippet and wrote it into a block
headed **"Givens — verified on `main`, treat as true"**, which instructs the model not to question it.

That heading is the whole problem. A Givens block converts my confidence into the model's constraint.
When I am right it saves a round — #0090 went from 1289s to 139s on exactly that mechanism. When I am
wrong it removes the model's licence to notice, and it spends the budget forcing my error to work
instead of reaching for the thing that does.

**The rule:** *nothing goes in a Givens block that I have not executed.* Not reasoned from something I
executed — executed, in the same context the model will run it in. If I want to suggest an unverified
approach, it goes in the Notes as a suggestion, where disagreeing is allowed.

**Corollary for review:** when a round burns its whole budget on one obstacle, suspect the givens
before suspecting the model. Round 1 here was competent — real `Process`, real pipes, fails loudly
rather than skipping — and it was defeated by a single line I told it to trust.

The verified form, probed inside a running test bundle, anchors on a type in the test target:
`Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()`.

### 1.13 My verification probe changed the thing it was measuring

Following 1.12, I set out to verify the *corrected* locator myself rather than trust the reviewer's
probe. My test did two things in one function: resolve the binary via `Bundle(for: BundleAnchor.self)`,
then assert that `Bundle.allBundles` finds no `.xctest` bundle — expecting to confirm the reviewer's
diagnosis.

The second assertion failed. `allBundles` **did** contain `YardKitPackageTests.xctest`, which read as
the reviewer being wrong.

It was not. `Bundle(for:)` **registers** the bundle, and my probe called it on the line above. The
measurement had been contaminated by its own setup. Probing each form alone settles it:

| probed alone | result |
|---|---|
| `Bundle.allBundles` | `count=1`, no `.xctest`, `main` = `…/usr/libexec/swift/pm` |
| `Bundle(for: BundleAnchor.self)` | `…/.build/arm64-apple-macosx/debug`, binary present |

So the reviewer was right, and the real finding is sharper than either of our first statements:
`allBundles` is **order-dependent** here. It works if anything earlier in the process touched
`Bundle(for:)`, and not otherwise — which is a flake waiting to happen rather than an honest failure,
and strictly worse than a method that never works.

**The lesson:** when a probe contradicts a careful reviewer, suspect the probe. Isolate each claim in
its own run before concluding anything — a probe that establishes state and then measures it is
measuring itself. This is the same shape as the vacuous test in §3.8, one level up: the evidence was
real and the inference from it was not.

### 5.1 Did the failure log actually help? Measured, not felt

`docs/review-failures.md` and `scripts/preflight-issue.sh` landed at 19:08. Here is the record either
side of that line, from OpenCode's session database and the issue files.

**Before 19:08 — 8 rounds across 5 issues.** #0010 timed out at the cap and was split for being
oversized. #0011 took two rounds and was split. #0070 needed three, the first accepted then rejected
on re-verification. #0098 round 1 died on a sandbox denial. #0085 converged first try. #0090 round 1
was rejected.

**After 19:08 — 10 rounds across 6 issues.** #0090, #0086 and #0087 each converged on round 2.
#0091 and #0092 converged on round 1. #0093 and #0102 were rejected on round 1 and are re-authored.

**What genuinely improved:**

- **Nothing has needed a third round.** Before, two issues went to three rounds or were abandoned;
  after, every accepted issue landed in one or two.
- **First-round acceptance went from 1 in 5 to 2 in 6.** Real but modest, and too small a sample to
  lean on.
- **The preflight has refused defective issues before a round was spent** — #0092 carried the same
  stale-branch reference that cost #0090 a 1289-second round, and #0093 named no source file. Those
  are rounds that never happened, so they appear in no timing comparison.
- **Fixes generalised.** The XCTest-invisible-count defect was fixed once and then applied to all
  nineteen dispatch-ready M1 issues; the executable-target defect was found in #0085 and removed from
  four queued issues before any of them ran.

**What did not improve, and this is the honest part.**

One failure family keeps recurring in a new costume each time: **a check that cannot fail.**

| round | the costume |
|---|---|
| #0011 r2 | a test named `envelopeFailWriteEmitsJsonToStdout` that never calls `write()` |
| #0090 r1 | `for code in allCases { guard case .ok = code else { continue } }` — ten cases, one tested |
| #0087 r1 | an extractor that returns `[]`, so the assertion is `[] == []` |
| #0102 r1 | a guard test still forbidding the *old* path — passed unchanged, guarding nothing |
| #0086 r1 | a test count that was identical with the new files deleted |
| #0102 r1 | a `grep '"yard"'` criterion that cannot match an interpolated literal |

Each was caught, logged, and given a detector. **Each next one wore a shape the previous detector
could not see.** The `INERT` scan cannot see `[] == []` because there is an `#expect`; the `TAUTOLOGY`
scan cannot see a stale guard because the literal is plausible; no scan sees a grep that is simply too
narrow.

**So the accurate claim is not "fewer failures". It is: no failure class has recurred once logged,
and novel ones keep arriving at a steady rate.** The mechanism converts *"the same mistake
repeatedly"* into *"each mistake once"*, which is worth a great deal and is not the same as
improvement in the raw failure rate.

**And the last three failures were mine, not the model's.** #0093 died on a Givens snippet I had
reasoned rather than executed. #0102 died on a grep I wrote that could not match the defect it was
looking for. Both were labelled as verified fact. The model did what it was told, and what it was
told was wrong — which is why the checklist now asks whether a grep was run against known-bad input
before being written into a criterion, and why nothing may enter a Givens block unexecuted.

### 3.7 Review feedback can make the next round impossible

Round 2 of #0070 was killed by the sandbox because *my feedback* told it to verify git behaviour,
which needs a scratch directory it is not allowed to create. The feedback was correct about what was
wrong and wrong about who should establish it.

**Fix:** state verified facts as **givens** in feedback. Verification is the reviewer's job; the
implementer applies the conclusion.

## Part 4 — Engineering findings that cost time

Not workflow problems, but each was a silent failure worth remembering.

- **`DispatchGroup.wait()` starves Swift concurrency's cooperative thread pool.** Draining two pipes
  concurrently and blocking hung the entire test suite for 7+ minutes with no subprocess alive.
  Invisible with one test; only parallel execution exposes it. Fixed by sending stderr to a file so
  there is one pipe and no blocking wait.
- **`git stash create` silently ignores `-u` / `--include-untracked`.** It yields a 2-parent commit
  with tracked changes only; only `git stash push -u` gives the 3-parent form, and `push` mutates.
  The design document asserted the opposite, and building on it would have dropped every untracked
  file from every snapshot.
- **`git rev-parse --show-toplevel` fails in a bare repository** rather than printing nothing, so
  asking for it alongside `--git-dir` made every bare repo look like "not a repository".
- **`--git-path` returns uncanonicalized paths** — `/var` vs `/private/var` compares unequal against
  a canonicalized `$GIT_DIR`.
- **libgit2 1.9.6 cannot open a reftable repository at all**, and shows no benefit from a
  `commit-graph` where `git` plumbing is ~5× faster.

---

## Open problems

- **LM Studio `PARALLEL 2`** caps useful fan-out at two rounds. Raising it is untested.
- **Round wall time is 8–26 minutes**, so a three-round issue can take over an hour. Whether tighter
  authoring reduces round count is not yet measured — the `Rounds` column exists to answer this.
- **No automated check that a round's tests assert the spec** rather than the implementation. Caught
  by human review twice; both times it was nearly missed.
