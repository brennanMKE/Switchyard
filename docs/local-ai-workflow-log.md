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

### 2.5 The output token cap was silently truncating tool calls

Two rounds died on the same night, both at the full 1800s cap, both producing **nothing at all**:

```
✗ Write failed
Error: The write tool was called with invalid arguments: SchemaError(Missing key at ["content"]).
```

#0014 emitted that **188 times over 25 minutes** without recovering. #0013 hit it four times, three
consecutively, then stalled until the watchdog killed it.

**The cause is configuration, not the model.** `~/.config/opencode/opencode.json` capped this model at
`"output": 8192`. That budget has to hold the model's reasoning **and** the entire file, JSON-escaped,
inside a single `write` tool call. A ~550-line deliverable — #0020 shipped 191 source + 362 test lines
and is the closest completed analogue — does not fit. The generation is cut off mid-call, the
`content` key never arrives, and the schema rejects it.

**It is intermittent in exactly the way that hides the cause.** Grepping every round log: 188
occurrences in #0014, 20 in #0012 round 2, 16 in #0010 round 1, 1 in #0090, zero in the other 20+.
Small edits fit and succeed; large greenfield files do not. So it reads as flakiness rather than as a
ceiling, and **both rounds that ever hit the timeout were writing a large new file from scratch.**

**Fixed** by raising the cap to `16384`, with the previous config backed up beside it. Input budget
falls from 57,344 to 49,152 within the same 65,536 loaded context, which is the real trade — rounds
already compact, and more frequent compaction is cheaper than a round that emits nothing.

**Two lessons worth separating.**

The first is about diagnosis: *a symptom that looks like model incompetence can be a numeric limit.*
The #0014 round's reasoning was correct and complete — it had independently derived the delimited
`%x01` format this issue turns on, and named every type it intended to create. All of it was lost to
a truncated JSON payload. Reading only the outcome would have concluded the model could not do the
task.

The second is about retries: the model re-emitted the identical failing call 188 times. `AGENTS.md`
Rule 5 already said a clear stop beats a third attempt; it now has **Rule 5b** saying the same about
tool mechanics, with a heredoc fallback for when `write` fails twice. A ceiling is not something a
retry can clear.

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

**First fix, which did not work:** every dispatch prompt was given a line saying to poll with
BashOutput until the process *actually exits*, and not to report before then.

**It recurred.** #0102 round 2, dispatched with that exact instruction in the prompt, reported
*"Baseline captured. Waiting for the dispatch to exit."* and stopped. So the instruction is necessary
and not sufficient — which is the same lesson as §1.6b and §2.4b: *writing a rule down does not stop
the behaviour.*

**Why an instruction is weak here.** "Do not report before it exits" asks the agent to recognise a
state it is already in the middle of misjudging. The agent does not experience stopping — it emits a
sentence that reads to itself like a status update, and the turn simply ends. There is no moment at
which it decides to stop.

**Second attempt — target the sentence, not the intent:** *"if you are about to write 'waiting' or
'I'll check back', make another tool call instead."* Better, but still an instruction, and
instructions have now failed once at this exact spot.

**Third, structural: `scripts/await-dispatch.sh`.** Waiting stops being a decision. The script blocks
inside a tool call for a budget under the 10-minute foreground limit, then exits **0** if the
dispatch has finished or **75** if it is still running, meaning *call me again*. The agent either
holds a result or must make another call. There is no state in which "wait" is something it can
merely intend, so the sentence that ends the turn has nowhere to appear.

That is the difference between the three attempts: the first two asked the agent to recognise a
boundary it demonstrably cannot see; the third removes the boundary.

**And the recovery is what actually matters.** `SendMessage` resumes the agent from its transcript
with full context, so a premature stop costs a round-trip and nothing else — but only if it is
noticed. **Treat a dispatcher whose report contains no verification results as unfinished, not as a
status update.** That check is on the reader, needs no cooperation from the agent, and has caught it
both times.

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

### 3.10 Naming the file is not naming the API

#0012 named its output file, its twelve fields, and its acceptance criteria. It named no
collaborators. The round wrote 679 lines against `GitProcess.GitRunner` and `Platform` — a protocol
and a conforming type it invented as an injection seam — and **did not open `GitProcess.swift` until
the last five lines of a 1443-line log**, after four rewrite cycles against phantom types. The cap
killed it with no test file written at all.

This refines §3.6, which has been load-bearing all evening. *Name the file* fixed convergence because
it forces the author to decide where code goes. But a path says nothing about what the code may
**call**, and a model with no stated API will infer one — reaching, reasonably, for something
injectable, because that is what testable code usually looks like.

**Fix:** when an issue depends on existing types, quote their real surface in the Givens, and say
explicitly when there is *no* abstraction to implement. `GitProcess` is a concrete `Sendable` struct
constructed as `GitProcess()`; the tests run against real repositories from `FixtureRepository`, so
there is nothing to inject. That sentence, absent from round 1, is the whole difference.

**The generalisation:** an issue is a contract about an unfamiliar codebase. The author has read it;
the implementer has not. Every type the work must touch is a place where "obvious" diverges between
them — and the model's guess will be idiomatic, plausible, and wrong.

**Also note what breadth did.** Twelve fields, sibling-worktree resolution, both ref formats, and a
test suite in one round. Even had the API been right, the budget was thin. Signing configuration
became #0108 and the sibling worktree #0109 — neither is needed to answer "where am I", and both are
independently useful. Splitting after a failure is cheap; the work was never started.

### 1.14 `/loop` is the heartbeat that makes stopping recoverable

The single most persistent failure in this project has one mechanical cause: **a turn ends when a
response contains no tool calls.** Background work re-invokes the session when it finishes; nothing
else does. So a turn that ends with prose and nothing running stops the queue silently, and stays
stopped until a human notices.

It has happened at every level:

- **§1.4** — a progress report between issues ends the turn, however it is phrased.
- **§1.11** — a dispatcher subagent writing *"waiting for the dispatch to exit"* and stopping, twice,
  the second time with an instruction in its prompt telling it not to.
- **And again on 2026-08-07**, by me: I said "I'll keep two rounds in flight through the night",
  dispatched nothing, and said goodnight. Brennan's next message was *"why did you stop working?"*.
  Prose about future intent is not a scheduled action.

**The fix is `/loop <interval> <prompt>`.** It arms a wakeup that re-invokes the session on a timer
**regardless of whether anything is running** — which is precisely the case no notification can cover,
because there is nothing to notify about.

**Use it as a fallback, not as the primary signal.** Harness-tracked background work already
re-invokes on completion, and that is far more responsive than any interval; polling for it just
burns wakeups. The heartbeat exists for what notifications structurally cannot catch:

- a round that hangs and never completes,
- a notification that is missed,
- and the real one — **both dispatch slots idle because the previous turn ended without dispatching.**

**Pick the cadence from the failure, not from the work.** An hour is right here: a stalled queue then
costs at most an hour, which is the actual damage being bounded. A five-minute heartbeat would not
make rounds finish sooner — rounds take ten to thirty minutes and announce themselves — it would only
add wakeups.

**What each firing should do,** in order: confirm both slots are busy; merge anything that finished
and set its status; dispatch from the ready queue until both slots are full again. If the queue is
genuinely empty or blocked, that is when the loop should stop rather than tick.

**The general shape worth carrying to other projects:** when a failure mode is *"the agent stops
without meaning to"*, no instruction fixes it — §1.11 proves that directly, since the second stop
happened with the instruction present. Recovery has to come from outside the turn. `/loop` is that
outside.

### 3.11 Rounds that repair converge; rounds that create a large file do not

Every timeout in this project has been a round writing a **large new file from scratch**: #0010,
#0012 round 1, #0013, #0014 rounds 1 and 2, #0113 round 1. Every round scoped as a **repair** has
converged, and quickly: #0012 round 3 in 504s, #0020 round 3 in 246s, #0102 round 2 in 132s.

That is not a statement about difficulty — the repairs were fiddly and the greenfield files were
ordinary. It is about **recoverable state**. A repair starts from something that exists and can be
built; each step either compiles or does not, and the round can stop mid-way having improved things.
A monolithic write is all-or-nothing: #0014 round 2 emitted 306 lines with `{ ... }` placeholder
bodies still in them, declared three properties twice, and then spent twenty minutes and seven builds
failing to dig out. Nothing it produced could be kept.

**So the shape to aim for is: make the first round produce something that compiles, however little.**
Types and signatures first, `swift build`, then bodies. A file with two working functions is a
foundation; a file with twelve stubbed ones is a liability, because the next round inherits the
confusion rather than the progress.

**Practical consequences already applied.** The dispatch prompt tells the model to build incrementally
and to use a heredoc if `write` fails twice. Reviews that follow a failed greenfield round should be
written as repairs against whatever landed, naming each defect — that is what turned #0012, #0020 and
#0102 around. And an issue whose deliverable will exceed roughly 200 lines should be split *before*
it is dispatched, not after it fails.

**One caution.** This is a correlation across ~30 rounds on one model, not a law. What it justifies is
a default — prefer repair framing, prefer smaller first deliverables — not a refusal to ever create a
file.

### 2.6 The sandbox rule survived three escalations and still fired

The `/tmp` rejection has now cost or damaged four rounds — #0070 r2, #0098 r1, #0113 r1 and #0113 r2 —
and each fix was a level more forceful than the last:

1. Fixed the **issue** that reached for `/tmp`. It recurred three issues later (§2.4b).
2. Added **`AGENTS.md` Rule 6**, the file OpenCode loads. It recurred (#0113 r1, fatally).
3. Put the rule in the **dispatch prompt itself**, which every round receives directly. **It recurred
   again** — #0113 round 2 ran `cat > /tmp/probe-fixture.sh` and was rejected.

So the honest conclusion: **prompt-level instruction does not stop this model reaching for `/tmp`.**
Three escalations of the same kind of fix produced the same outcome, which is the signal to stop
escalating that kind of fix.

**What did change is the failure mode, and it is worth separating.** Round 1 died 245s after the
rejection, having stopped one sentence later. Round 2 absorbed the rejection and worked for another
twenty minutes, producing both files. The prompt rule converted *fatal* into *survivable*. That is a
real gain and not the one that was intended.

**Two conclusions.**

The narrow one: for anything that needs a repository fixture, **generate the bytes yourself and paste
them into the issue.** #0113 asked the model to run `git status --porcelain=v2 -z` and read the
output; it failed twice, and both failures cost a round. Capturing the five records took me under a
minute in a directory I am allowed to write to. An issue that hands over evidence beats an issue that
asks for it to be discovered, whenever the discovery is cheap for the author and blocked for the
implementer.

The general one: **when three escalations of the same fix fail, the next fix must be a different
kind.** More forceful wording is the same kind. The different kind here is a sandbox permission change
in `~/.config/opencode/opencode.json` — untried, because the schema was not to hand and guessing at a
permission config on someone else's machine at 3am is a worse idea than pasting bytes into an issue.
It remains the right fix if this keeps happening.

**It kept happening.** #0107 — a three-minute deletion that converged first try — still reached for
`/tmp`, to redirect the CLI's streams while verifying. That is the **fourth** round, and the first
where the purpose was something as ordinary as capturing stdout rather than building a fixture. It
was harmless there because the edit and the tests were already done, but it makes the pattern
unambiguous: **this model reaches for `/tmp` whenever it wants a scratch file, and no amount of
instruction changes that.** Four rounds, three escalations, one config change still untried.

The next person to hit this should make the permission change rather than write another rule.

### 3.12 Prose has no test, and fluency reads as accuracy

#0111 asked for one thing: three doc comments named commands the code does not run, so correct them.
The round passed **every** guard — 181 tests exactly, comments-only proven by
`git diff -U0 | grep -vE '^[+-][[:space:]]*///'` returning nothing, no scope violation, no `/tmp`
reach — and left the file **less accurate than it found it**.

Each of the three real corrections was padded with invented detail: an `ls-files`/`-z` pipeline that
does not exist, an assurance that staged and unstaged counts "should match in practice" when they
routinely differ, and advice to treat a SHA shorter than seven characters as unborn when no length
check exists anywhere.

**Nothing mechanical could have caught this.** There is no test for a comment. The inert-test detector,
the preflight, the count check — all of them passed, correctly, because none of them read English
against code. It took a reviewer opening the function body and checking each new sentence against it.

This is §3.2 and §3.8 again in the medium where those tools do not reach. The earlier ones were
assertions that were present but wrong, and counts that were real but did not move. Here it is
sentences that are plausible but false — and prose is the one deliverable where **plausible is the
whole attack surface**, because there is nothing else to check it against.

**Two practical rules.** When commissioning documentation, say that each sentence must name something
visible in the code, and that elaboration is not wanted: *a doc comment may not contain a claim that
would need a test to be true.* And when reviewing it, read the prose against the implementation line
by line — the same discipline as re-running a test rather than reading its name, applied to the one
artifact that cannot be run at all.

### 3.13 Criteria-shaped code: the vocabulary without the behaviour

#0106 asked for three specific things — walk the tree recursively, match `@testable import X`, assert
the file set is non-empty. Round 1 delivered source containing `FileManager.enumerator`, the string
`"@testable "`, and `#expect(!swiftFiles.isEmpty)`. Every criterion is visibly represented. **Three of
the four mutations still passed**, meaning a layering test that cannot detect a layering violation.

The two defects are worth stating precisely, because each is invisible in review by reading:

- `stripImportAttributes` strips `@testable `, `internal ` and `public ` — and never strips
  `import `. The caller then asks `marker.hasPrefix("YardKit")` of a string that always begins
  `import `. **False for every real import line**, forever.
- `enumerator.skipDescendants()` is called on every directory, which means *do not descend*. The
  recursive walk never goes below one level and the `recursive:` parameter is inert.

**This is the fifth costume of "a check that cannot fail" in one session**, and the first where the
predicate operates on real data and still cannot fire. The earlier four — an assertion-free test, a
loop that `continue`s past all but one case, `[] == []`, a test count that does not move — are each
caught by something mechanical. This one is not. `check-tests-assert.sh` passed correctly: it looks
for missing assertion macros and `return`-shaped skips, not predicates that are structurally
unsatisfiable.

**The general shape:** when acceptance criteria name specific mechanisms, a round can satisfy the
*naming* without the *doing*, and every artefact-level check — the diff, the test count, the detector,
a careful read — will agree that it complied. The words are there.

**So the only reliable verification is mutation.** Break the thing the assertion guards; confirm it
fails. That is not a nice-to-have on top of the other checks, it is the only one of them that can
distinguish a working guard from a decorative one. Every review in this project now leads with the
mutation table rather than ending with it.

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

### 5.2 Probing the tool before authoring changed what got built, twice in one night

#0096 and #0097 both carried a Givens block probed on 2026-08-06. Re-probing the same commands on
2026-08-07 — because both issues were about to be dispatched and the checklist says to name
affordances rather than requirements — turned up three things the earlier probe had not asked about.

- **`git worktree list --porcelain` already reports `prunable <reason>`.** #0096's Expected behavior
  said "reports prunable worktrees with git's own stated reason", which reads like a discovery
  routine to write. There is nothing to write; it is a field in output the code already parses.
- **A locked worktree whose directory is gone is never reported prunable and is never reaped.** So
  #0096's headline criterion — *never removes a worktree still locked by a live agent session* — is
  git's guarantee, not code. An implementation that "adds" it would be adding a second, weaker copy
  of a guarantee already in place. What actually remains is the *report*, because git will never
  clean those entries up on its own.
- **Both `prune -v` and `repair` write to stderr.** `GitProcess.Output.text` and `.lines` are stdout
  only, so a round parsing them reports "nothing to prune" and "nothing repaired" for every
  repository, in code that looks entirely correct and passes any test whose fixture has nothing to
  prune. That is a rejection in both issues, and neither issue mentioned it.

Then the finding that reversed a design decision: **`git worktree prune` cannot tell a moved worktree
from a deleted one, and reaping a moved one is unrecoverable.** Move a worktree, and the porcelain
reports its old path as `prunable gitdir file points to non-existent location` — byte-identical to a
deleted one. Prune reaps it, the directory stays on disk full of the user's work, and
`git worktree repair <newpath>` now exits 1 with *"unable to locate repository"*. Before the prune,
that repair would have succeeded.

So `wt gc` reports by default and prunes only under an explicit `--prune`, rather than pruning by
default with `--dry-run` available. That is not a preference; it is the probe.

**The general form:** §3.6d said verifying the tool beats transcribing its `--help`. This is the
stronger version — verifying the tool beats *transcribing a previous verification*. The 2026-08-06
probe was accurate about everything it asked. It just did not ask whether git already solved the
problem, and that is the question that changes the issue.

### 1.15 I overwrote a resolved issue with a shell redirect

`cat > issues/0113.md` to file a new issue. #0113 already existed — *Parse git status porcelain v2
into per-file entries*, resolved hours earlier — and the redirect clobbered it silently. Recovered
from `bb97107` and verified byte-identical; the new issue became #0114.

Two mistakes, and the second is the interesting one:

1. I picked the next number from the **open** issue list, which by construction cannot contain
   resolved issues. The number has to come from every `NNNN.md` on disk.
2. I used a tool that overwrites. `>` has no opinion about whether the target exists.

Nothing in the harness caught it. I noticed only because this log happens to mention "#0113 round 1"
in a paragraph about timeouts, and that did not match the issue I had just written — a coincidence,
not a check.

`scripts/new-issue.sh` now allocates the number over all files below 8000 (so the reserved 8888/9999
test issues do not drag allocation up) and refuses to write to a path that exists. Both directions are
controlled: it allocated past a resolved #0113 and an open #0114 to land on #0115, and the guard fires
when pointed at an existing path.

Writing it turned up a second thing worth recording: **`cat` and `date` are not reliably available to
a script the sandbox runs**, even when the calling shell has both. `ls`, `sed`, `grep`, `awk`, `sort`
and `tail` all worked in the same script; `cat` and `date` failed with *command not found*. The fixes
are zsh builtins — `$(</dev/stdin)` and `zmodload zsh/datetime; strftime` — which are better anyway.
Any script in `scripts/` that shells out to `cat` or `date` should be assumed broken until run.

### 5.3 Probe the code, not only the tool

§5.2 was about re-running `git` before authoring. This is the other half: **run the code the issue is
about, against real input, before writing a word of the issue.**

#0013 was due to be re-authored after #0113 landed the porcelain v2 parser. Instead of reading the
parser and describing what was left to do, I fed it real
`git status --porcelain=v2 -z --ignored` bytes from a fixture containing a rename, a submodule, a
path with a space, a path with a **newline**, a conflict, an untracked file and an ignored file —
seven files. Six came out. Then a record whose path is the two bytes `0xFF 0xFE`: **zero** came out,
the entire status silently empty.

Three defects, none of which the existing tests can see:

- **Renames are dropped by an off-by-one.** `fieldCount["2"] = 9` puts the path index one past the
  last token, so `path` is `""` and the `guard !path.isEmpty` two lines down discards the record
  without a trace. #0113's tests pass because none of them contains a rename.
- **One non-UTF-8 byte erases the whole status.** `String(data:encoding:.utf8)` returns nil and
  `parse` returns an empty list — reported as success, indistinguishable from a clean worktree.
- **Submodule state is flattened.** The `<sub>` field (`SC..`, `SCMU`) is read into a variable and
  never used.

**The issue that came out of this is a repair with five named mutations and a measured before-count.
The issue I would have written from reading the source would have been a feature request.** That is
the difference the probe makes, and it took four minutes.

It also settled a requirement that could not be built: the original #0013 asked for "renames and
copies reported as such", and **`git status` has no copy detection** — `--porcelain=v2 -C` fails with
``unknown switch `C` ``. A round would have spent itself discovering that, or worse, invented a
`copy` state nothing can produce. Now guide §11 decision 7.

The general rule, and it is cheap: **before authoring an issue against code that already exists, run
that code on the input the issue is about and print what comes back.** A throwaway test in the
existing target, deleted immediately, is enough. Reading the source tells you what it intends;
running it tells you what it does.

### 5.4 `@testable import` hides an entire class of defect

`gitStatus` is `public` and returns a `public struct WorktreeStatus` whose `entries` property is
**internal**. An out-of-module caller can obtain the value and do nothing with it. Proved with a
throwaway SwiftPM package depending on the `YardGit` product:

```
error: 'entries' is inaccessible due to 'internal' protection level
```

**No test in the suite can catch this**, because `YardGitTests` uses `@testable import YardGit`,
which grants internal access. The tests and the caller are compiling against different modules. Every
test passes against an API nobody can use.

The same probe compiled clean for `whereAmI`, `worktreeList`, `worktreeRemove` and `yardWhere` — so it
is one type, not a systemic rot, and #0116 is scoped accordingly. What #0116 also builds is the check:
a test target that imports **without** `@testable`, where reverting `entries` to internal must break
the compile. That is the only construct that sees what a caller sees.

Worth stating plainly because it generalises past Swift: **a test harness with extra privileges cannot
verify a boundary defined by privilege.** Anywhere the tests get a capability the caller does not —
`@testable`, a friend class, a test-only export, a mock that bypasses an interface — the boundary
needs its own check compiled at the caller's level.

### 3.14 A round that ends with a question is a stop, and nothing had said so

#0096 round 1 wrote `WorktreePrune.swift` correctly — it read `standardError` rather than `.text`,
which is the defect the issue warned about hardest, and against a real fixture it classified an
agent-locked deleted worktree as an abandoned session, reported the unlocked one with git's verbatim
reason, and left the locked one alone.

Then it stopped. **4,251 output tokens**, one file, and a final log line:

> *"Would you like me to proceed with step 1 (write tests) and the rest of the verification
> workflow?"*

It had just enumerated its own four remaining steps. It knew exactly what was left. No test
references `WorktreePrune`, so all four required mutations were unrunnable and each left the suite
green at exactly the 225 baseline — the round verified nothing at all.

**This was not disobedience.** `AGENTS.md` had nine hundred words on what a round must verify and
nothing saying it must not stop to ask. The model is running unattended; whatever it asks goes into a
log nobody reads until after it has stopped. Now Rule 9: do every unambiguous part first, take the
most literal reading of the criteria, and state the assumption at the end after the suite has run. An
unanswered question at the end of a finished round is useful; a question instead of a finished round
is the one outcome that cannot be reviewed.

Two of the issue's own defects contributed, and both are now checklist items:

- **Expected behavior named only a file.** "Reporting is the default, pruning is opt-in" had no
  signature to attach to, so the round produced `report(...)` and `runPrune(...)` as two unrelated
  statics with nothing choosing between them. A default needs a parameter, and a parameter needs a
  signature — write it into the issue (item 22).
- **The stated baseline was stale**: 216, when `main` was 225 after three merges. A stale baseline
  hides a small increase, which is precisely what the criterion exists to catch. `docs/test-baseline.txt`
  now records the real count and preflight check 4b compares it. Controlled both ways.

Writing check 4b produced its own small lesson: the first version read `$SPEC` as if it held the spec
text, when it is a **temp file path**. The check silently never fired and printed nothing — the same
shape as §3.6c's guard that could not fail. It was caught only because the negative control was run.
**Every new check gets both controls, every time.** That rule has now paid for itself twice.

### 1.16 A dispatcher subagent refused three ways around a guard, and was right

#0013's re-dispatch was blocked: `dispatch-issue.sh` requires a `## Review` section for any round
after the first, and round 1 had been killed at the timeout months of context ago, producing nothing
to review. The dispatcher tried `--force`, was denied by the permission layer, and then **stopped
rather than route around it** — explicitly rejecting three workarounds it had already identified:
dispatching as `--round 1` (which would overwrite round 1's log and misattribute the cost), renaming
the previous round's log (deleting the guard's input to defeat the guard), and writing the `## Review`
section itself (a spec edit, which is not the dispatcher's to make).

That is the behaviour the guards are for, and it is worth recording as a success rather than only
logging failures. The fix was one minute of authoring: say under the heading that round 1 produced
nothing and what has changed since. **"Nothing to review" is itself the review**, and the model needs
to read it. The guard's message now says so, so the next person does not reach for `--force`.

One thing that did go wrong: I first placed that section *before* the Givens, and preflight reads
everything above the first `## Review` as the spec — so the Givens, the Expected behavior and the
verification command all fell outside it and two hard checks failed. Reviews go at the end of the
file. The check caught it in three seconds, which is the entire argument for running preflight rather
than trusting a read-through.

### 5.5 What the probing pass covered, and what came back clean

§5.3's technique was applied to every public surface in the package on 2026-08-07, so the result is
worth recording in full — a clean probe is only useful if nobody repeats it.

**Defects found, each now an issue with measured before-counts:**

| surface | defect | issue |
|---|---|---|
| `WorktreeStatusParser` | renames dropped by an off-by-one; one non-UTF-8 byte erases the entire status; submodule state flattened | #0013 |
| `CommitLog.parse` | a body containing the `\u{01}` field delimiter is truncated at that byte, losing the trailers with it | #0117 |
| `WorktreeContext.resolveRef` | returns `nil` for every shared ref, indistinguishable from "does not exist" | #0119 |
| `gitStatus` | returns a `public` type whose members are internal — unusable from outside the module, invisible to `@testable` tests | #0116 |
| `WorktreeRemoveTests`, `WorktreeStatusTests` | never parameterised over reftable, unlike the other seven test files | #0118 |

**Probed and correct — do not re-check these:**

- **`GitProcess`.** Pointed at a non-existent executable, both `capture` and `run` throw
  `could not launch git`. `capture` does **not** throw on a non-zero exit (`git config --get` of a
  missing key returns `exitCode == 1` quietly); `run` does, as `Failure.exited`, carrying stderr. A
  non-existent working directory is not a launch failure — `capture` returns 128 with
  `fatal: cannot change to …`, so it cannot be used to provoke a throw.
- **`EnvelopeErrorCode` → `ExitCode`.** All ten cases map one-to-one to 0–9 with matching
  `codeLabel`s, and every one round-trips through the JSON envelope with `schemaVersion: 1` and
  `ok: false`.
- **`worktreeList`.** Correct against worktree paths containing spaces and double quotes, and lock
  reasons containing spaces.
- **`WorktreeContext.resolve` inside a git submodule**, where `.git` is a *file* pointing into the
  superproject's `modules/` directory: `gitDir` and `commonDir` both resolve to
  `…/super/.git/modules/sub`, `topLevel` is the submodule directory, `path(for: "HEAD")` resolves,
  and it is correctly reported as neither linked nor bare.
- **`gitStatus` and `worktreeRemove` under `--ref-format=reftable`.** Both behave identically to
  `files`. #0118 is a coverage gap, not a bug — a round that "fixes" either implementation is wrong.
- **`CommitLog`** on multi-paragraph bodies, blank lines, CJK, accented Latin, emoji, merge parents,
  trailer blocks, and `-1`/range arguments. All round-trip.

Five real defects in about ninety minutes, in code that was already reviewed, already tested, and
already merged. None of them were visible from reading; every one showed up the moment real input went
in and the output was printed.

## Part 6 — The workflow revision of 2026-08-07

### 6.1 What fifty rounds actually measured

One day, one model, fifty dispatched rounds. The numbers are the argument for everything below.

| | |
|---|---|
| Rounds dispatched | **50** |
| Accepted | 24 |
| Rejected | 22 |
| Failed outright — hung, timed out, no code | 3 |
| Guard refusal, no round spent | 1 |
| **Accepted that needed a hand finish** | **16 of 24** |
| **Accepted clean** | **2** |

23 issues resolved, $23.62 in Opus tokens, ~131 million Ornith tokens at $0.00. So the local model
produced complete, acceptable work **twice in fifty rounds**, and roughly half of all rounds produced
nothing usable.

And the outcome that matters more than any of it: after 23 resolved issues and 311 tests,
`switchyard whereami` still answered `Unknown subcommand`. **Nothing shipped.** The engine was
excellent and the product was zero.

### 6.2 The correlation that drove the redesign

Sorted by how the issue was written, the pattern is not subtle:

- **Issues carrying measured code converged in one round.** #0117 (a one-line parser fix with the
  `od -c` bytes in the issue), #0110 (a conflict count with both candidate commands measured against
  a real repository), #0118 (a coverage gap with the trap — a parameterised `@Test` counts as one —
  stated up front, plus two substitute proofs).
- **Issues describing the work in prose did not.** #0124 spent three rounds and never wrote a test.
  #0096 spent three and never got a working fixture. #0013 took three plus a hand finish.
- **The cleanest single experiment:** #0116 round 1 timed out at 1800s having rewritten its test file
  **26 times**, discovering signatures by compile error. Pasting five declarations into the issue took
  round 2 to **17 edits, finished inside the clock**. Nothing else changed.

Alongside that, two structural facts. **Every timeout was a round creating a large new file**; every
round scoped as a repair converged. And **Ornith fails on `Package.swift` and the Xcode project**
specifically, while landing single-file Swift repairs first time.

### 6.3 The five roles

| role | model | scope |
|---|---|---|
| Planning | **Fable 5** | Authors down to the code: exact paths, pasted signatures, literal lines, measured before-and-after values |
| Implementation, pure code | **Ornith**, local, $0.00 | Ordinary Swift against a target the issue already measured |
| Implementation, structural | **Sonnet 5**, billed | `Package.swift`, the Xcode project, build settings, the environment, the harness |
| Issue review | **Opus 5** | Re-runs verification, runs mutations, reads every test. Also reviews umbrella issues once their children resolve |
| Milestone review | **Fable 5** | Runs when a milestone's issues are all `resolved`; checks guide §9 exit criteria only |

`scripts/dispatch-issue.sh` takes `--model ornith|sonnet`, defaults to local, and says plainly when a
round is billed.

**A hand finish is expected, not a failure.** Sixteen of twenty-four accepts needed one. Pretending
otherwise costs a full round of latency on most issues. Review, finish the last small thing by hand,
re-dispatch only when the *shape* is wrong.

### 6.4 The counter-risk, which has already cost rounds

Colour-by-numbers is only safe if the numbers were measured. **A code sample written from memory
propagates silently** — #0093 shipped a `Bundle.allBundles` snippet reasoned from adjacent facts and
labelled verified, costing a full round; #0114's decisive test vector was unsatisfiable because
`GitProcess` was measured and `whereAmI` was assumed. The rule is now explicit: everything pasted into
an issue must have been run, and the issue must say so.

### 6.5 The first two planning passes, and what they caught

Both re-authored existing issues, and **each found a defect in text I had written and believed**:

| issue | the correction |
|---|---|
| #0109 | Givens said `GitProcess.run(_:at:)`. The label is `workingDirectory:` — the same wrong-label class that cost #0116 its clock |
| #0109 | Said a detached worktree merely omits `branch`. Measured, it also carries an explicit `detached` line, and `WorktreeList.swift` already parses both |
| #0108 | Its "absent config" criterion was **unimplementable**: `FixtureRepository` presets `commit.gpgsign=false`, so a fresh fixture is never unset |
| #0108 | The `gpg.ssh` subsection is case-sensitive — `gpg.SSH.…` returns nothing |

Four corrections, two issues, all verified independently before dispatch. #0109 grew 50 → 267 lines,
#0108 53 → 395.

**The backlog is therefore re-authored, not just new issues.** Most existing issues name no source
path at all, which preflight check 3 rejects outright.

### 6.6 Milestone exit criteria, and why not umbrella issues

Every milestone in guide §9 now states its exit criteria as a checklist, and the Fable review reads
those and only those. Two bounds make it terminate: it may file issues **only** against a stated
criterion, and **two consecutive clean reviews close the milestone**.

The distinction Brennan drew is worth keeping straight. An **umbrella issue** breaks *one feature*
into several small implementation tasks — that is how work is sized for a small model, and Opus
reviews the parent once the children resolve. A **milestone criterion** is a property of the whole
milestone, often spanning features, and frequently satisfied by no single issue.

#0115 is why the distinction matters: forty-two M1 issues passed review individually while "the
commands run" went unmet, and **no single issue's review could have seen it**. Per-issue review is
structurally blind to the gaps between issues.

M1's criteria carry the line that names the failure directly: *"Built" is not "engine function
exists."*

### 6.7 The `swift-guidance` skill belongs in all three roles

`~/.claude/skills/swift-guidance` encodes the project's expectations for Swift — concurrency and actor
isolation, logging, SwiftUI and Observation, dark mode, performance, multiplatform, and build
configuration. It is now named in planning, in the dispatch prompt, and in review.

Planning is the important one and the least obvious. A Swift block in an issue is copied close to
verbatim by the implementer, so an anti-pattern written into an issue propagates to every round that
follows it. Its `references/project-configuration.md` covers `MainActor` default isolation and strict
concurrency — precisely the ground #0126 turned on, where a package target does not inherit the app's
`SWIFT_DEFAULT_ACTOR_ISOLATION` and every moved view would silently change isolation.

Its stopping rule — one or two high-impact findings per area, then stop — is respected rather than
worked around. A review returning twenty findings buries the one that mattered.

### 6.8 What is being measured tomorrow

The hypothesis is narrow and falsifiable: **issues authored to code level should raise the
first-round accept rate and cut the hand-finish rate.** Today's baseline is 2 clean accepts and 16
hand finishes out of 24. If tomorrow looks the same, the planning change is not the lever and the
constraint is the implementer.

Secondary numbers worth watching: rounds lost to environment rather than code — today two hung
inferences, two mistyped-absolute-path sandbox rejections, roughly six `/tmp` rejections, one
output-cap truncation — and whether routing structural work to Sonnet removes the failures Ornith
could not clear in three attempts.

