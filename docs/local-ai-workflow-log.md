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
