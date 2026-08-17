# Switchyard

A SwiftUI macOS git client with an agent-facing CLI (`switchyard`). Successor in spirit to GitUp, built
so a coding agent is a first-class user of the repository alongside a human.

Two design documents, both current, both in `docs/`:

- **`docs/switchyard-development-guide.md`** — scope, architecture, CLI surface, milestones. Read it
  before designing anything. Settled decisions live in its §11; record new ones there.
- **`docs/switchyard-git-internals-and-undo.md`** — how the journal works against git's real
  on-disk state, the hook layer, and worktrees. **Read this before touching the journal, the ref
  layer, or any path resolution.** The guide says what to build; this says how git will make you.

`issues/` holds the task breakdown. This file is the working agreement: rules, commands, and traps.

## Autonomy: keep working through the queue

**The default is to keep going.** Work through open issues in order without reporting back after
each one. The tracker exists so work can proceed unattended; a check-in on something routine stalls
a queue designed not to need one.

**Proceed without asking** — these are pre-authorized, permanently:

- Creating `issue/NNNN` branches, committing rounds to them, squash-merging to `main`, and pushing
  `main` and issue branches to `origin`.
- Any decision already settled in `docs/switchyard-development-guide.md` §11, or implied by the
  issue's own Expected behavior.
- Ordinary implementation choices: naming, file layout, test structure, which of two equivalent
  approaches to take.
- Installing developer tooling needed by an issue (Homebrew formulae, SwiftPM dependencies already
  named in the plan).
- Cloning public repositories as test fixtures.
- Filing new issues when work reveals something the backlog missed.

**Stop only for these** — the list is deliberately short:

1. **Signing assets.** Anything in the Code signing section. Non-negotiable, always stop.
2. **Outward-facing actions on Brennan's accounts.** Pushing to a GitHub repo other than this one,
   registering an SSH signing key, publishing a release, anything that touches an external service
   as him.
3. **A decision that changes what gets built**, where two readings produce materially different
   work — the UI hierarchy question was a real example. Not "which name is nicer".
4. **A clean-room judgment call** — if it is unclear whether something is derived from GitUp.
5. **An M0 spike answering negatively.** #0002 or #0003 failing is an escalation; the project's
   premise depends on both.

**When blocked, do not stop — reroute.** Move to the next unblocked issue and collect blockers into
one batched question at the end of the session. One question with five items beats five
interruptions.

**A progress report between issues is a stop.** Emitting text ends the turn, so "here is what I
found, next I will do X" is functionally quitting, however it is phrased. Do not narrate transitions
between issues. Findings belong in `docs/` and in the issue files — that is the report, and it
persists. Keep taking tool calls until the queue is exhausted or genuinely blocked, then report once
covering everything.

**Never fake progress to avoid stopping.** The verification rules still hold: tests must actually
run, and an unverified issue stays open. Reporting an issue resolved to keep momentum is worse than
any interruption.

### Test repositories

Durable test and fixture repositories go in `/Users/brennan/Developer/brennanMKE/Git` — the same
directory that holds Switchyard, GitUp, and the `git/git` performance fixture. Create them there
rather than in the scratchpad when they are worth keeping between sessions. Programmatic fixtures
built by the test harness (#0024) still go in temp directories and are cleaned up.

### Running unattended

`/loop` is the harness mechanism for sustained work, and its real job is to be a **heartbeat that
makes stopping recoverable**. A turn ends when a response contains no tool calls; background work
re-invokes the session when it finishes, and nothing else does. So a turn that ends with prose and
nothing running stops the queue silently — which has happened repeatedly, including once after
promising to keep two rounds in flight overnight.

`/loop <interval> <prompt>` re-invokes the session on a timer **whether or not anything is running**,
which is the one case no notification can cover.

**Treat it as a fallback, not the primary signal.** Dispatch completions already wake the session and
do it sooner; polling for them wastes wakeups. The heartbeat catches what notifications cannot: a hung
round, a missed notification, and both slots idle because the last turn ended without dispatching.
Pick the interval from the failure being bounded — an hour means a stalled queue costs at most an
hour — not from how long a round takes.

**On each firing:** confirm a round is actually running, merge anything that finished and set its
status, then dispatch the next ready issue. Stop the loop when the queue is genuinely empty or
blocked rather than letting it tick.

Between firings the issue tracker is the state — status rows and branches say what is done, so a fresh
context resumes without needing the previous conversation.

### A milestone goal is the unit of work

Brennan sets goals as **"complete every issue in milestone MN"**, and that goal — not a single issue
— is what a session iterates against. There is no separate goal-tracking mechanism and none is
wanted: **the tracker is the goal's state.** `./scripts/list-recent-issues-by-milestone.sh` prints
open / in-progress / resolved per milestone, which is the whole progress report.

Working a milestone goal means, on repeat until the milestone's open count is zero: pick the next
open issue in that milestone, plan it to the standard below, preflight it, dispatch one round,
review, squash-merge, set it `resolved`, remove its worktree. Then the **milestone review** in guide
§9 runs, and its findings become ordinary issues in the same milestone — so the goal is not met when
the last issue resolves, it is met when two consecutive milestone reviews find nothing.

An issue that turns out to belong to a different milestone gets re-milestoned rather than dragged
into the goal, and an issue that is genuinely blocked goes back to `open` with the blocker written
into it — the goal moves on. Neither is a reason to stop and ask.

## Implementation is delegated

**Three roles, set 2026-08-16.** No local model, no OpenCode, no Fable.

| role | model | what it does |
|---|---|---|
| **Planning** | Opus 5 | Authors the issue **down to the code**: exact paths, exact signatures, the literal lines to change, measured before-and-after values. Not a description of the work — a colour-by-numbers of it. |
| **Implementation** | Sonnet | One round, one issue, in its own worktree. Spawned as a Claude Code subagent, never run from the main loop and never in the primary checkout. |
| **Issue review** | Opus 5 | Re-runs the verification, runs the mutations, reads every new test. This is where the catches happen. |
| **Milestone review** | Opus 5 | Runs when every issue in a milestone is `resolved`. See below. |

**Dispatch is a Claude Code subagent with `model: sonnet`, working in `../switchyard-NNNN`.** The
loop is otherwise unchanged: the subagent absorbs the round's transcript, Opus reviews the diff and
the *re-run* verification output, and the branch is squash-merged only after it passes.

**What the orchestrator owes the round, now that no script wraps it.** `dispatch-issue.sh` carried a
wall-clock timeout, a stall watchdog, a 3-round cap, a clean-tree check, a branch check and a `.done`
record. Every one of those exists because a round once looped, lied, or died quietly. With the script
out of the loop **those become the orchestrator's job, and they are not optional**:

1. **Run `scripts/preflight-issue.sh NNNN` before every round**, including re-dispatches. It is
   model-agnostic and still the gate; it also refuses an issue that is not `in-progress`.
2. **Create the worktree first** — `git worktree add ../switchyard-NNNN -b issue/NNNN main` — and
   give the subagent that path. A round in the primary checkout is the failure that cost us the
   2026-08-13 reset.
3. **Three rounds is the cap.** After the third, the issue goes back to `open` and is re-planned or
   split. Do not spend a fourth.
4. **A round that produces no `Test run with N tests` line is a failed round**, not a quiet one. An
   empty suite capture is indistinguishable from an unread one, which is how #0157 and #0180 both
   shipped code that did not compile.
5. **Remove the worktree once the issue resolves and the branch is merged.** Keep the branch —
   forever, per the squash rule below — but not 121 stale checkouts and 22 GB of `.build`.

**The `--model ornith|sonnet` flag, `scripts/dispatch-issue.sh`, `scripts/await-dispatch.sh` and
`scripts/ornith-tally.sh` are all retired.** They are kept for the guard logic they encode, which is
worth reading before re-implementing any of it, but nothing invokes them. `issues/ornith-tally.md`,
`docs/lm-studio-concurrency.md` and the Ornith rows in `issues/cost-ledger.md` are a closed
historical record.

### The dispatch prompt

Short, and deliberate about what it makes the round read: **`issues/NNNN.md` as the deliverable and
`AGENTS.md` as the rulebook.** #0017's round burned its whole budget on a mandated reading set and
wrote no code — that specific arithmetic was a 65k-context problem and no longer binds, but the
habit it teaches does. Reading is not free, and a round pointed at four documents is a round that
has not started.

The prompt carries, and nothing more:

- **The worktree path**, and that everything happens inside it — no absolute paths reproduced from
  memory, which has killed three rounds by typo (`brenbanMKE`, `tensorshare`).
- **The issue file to implement**, and that its Expected behavior is the deliverable list.
- **`AGENTS.md`'s numbered rules**, by reference, plus the licensing and signing rules inline if the
  round could plausibly touch either.
- **The `swift-guidance` skill**, to be loaded before writing Swift, not worked from memory.
- **The verification command and the line its output must contain** — `swift test` printing
  `Test run with N tests`. The round pastes that line or the round failed.
- **`.switchyard-runs/NNNN-roundN.report.md`, written before it finishes** — `AGENTS.md` Rule 4b.
  The round does not run git at all; its first line becomes the commit subject.
- **Stop at the issue's scope.** No edits to `CLAUDE.md`, `AGENTS.md`, the issue file, or any file
  the issue does not name.
- **Never assert wall-clock elapsed time.** The package runs seventy suites in parallel and most of
  them block in `git` subprocesses, so a `Task.sleep` can fire tens of seconds late and a reply can
  arrive long after a five-second deadline. Two tests asserting elapsed time cost #0048 a round, and
  five more with a five-second XPC deadline turned `main` red an hour later. Assert what the criterion
  claims — that a bounded loop **terminates**, that a call **succeeds** — and give any deadline in a
  test a generous value. Production defaults stay small; a CLI is one process making one call.

**Merge `main` into the branch before believing the round's count.** A round's number is a fact
about its branch; `main` moves under it while it runs. The habit that makes the baseline safe is
`git merge main` in the worktree, then run the suite there, then squash — and it is the same habit
that catches a semantic conflict between two rounds before it reaches `main`. **And re-run the suite
on `main` after the squash**: #0048 was green three times in its own worktree and red on `main` five
minutes later, because the merge raised the parallel load past what its deadlines tolerated.

**The orchestrator commits the round the moment it returns**, using that report as the message —
before reviewing it, not after. The script used to do this from an `EXIT` trap; now nobody does it
unless you do, and an uncommitted round is one killed session away from being the thing that caused
the 2026-08-16 reset. A round that produced nothing worth keeping is discarded with
`git checkout .` instead, which is a decision, not an omission.

The round's *report* is a verdict, not a transcript: what it changed, the suite line, what it could
not do. The subagent keeps the transcript out of the main context, which is the point of dispatching
through one.

### Why issues carry code, whatever runs them

Measured over fifty rounds on 2026-08-07 — a local model, but the pattern is about the *issue*, not
the model, and it held across every round since:

- **Issues that carried measured code converged in one round** — #0117, #0110, #0118. Issues that
  described the work in prose did not.
- **Pasting five function signatures into #0116** took round 2 from 26 file rewrites and a timeout to
  17 edits and a finish inside the clock. Nothing else changed.
- **Every timeout was a round creating a large new file.** Every round scoped as a repair converged.
- **Rounds asked to *design* a structural change failed; rounds handed the literal edit did not.**
  #0124 spent three rounds designing a `Package.swift` change and never wrote a test. #0129 pasted
  the ten-line manifest edit and it was transcribed byte-identically, first round, zero edits.

Sonnet is a stronger implementer than what produced those numbers, and that is a reason to expect
fewer rounds — **not** a reason to loosen the standard. The rule stands: **smaller issues, with the
code in them.** A vague issue wastes a Sonnet round at Sonnet prices.

### Every existing issue is re-authored before it is dispatched

The backlog was written before this standard existed. **An issue authored under the old approach is
not ready** — most name no source path at all, which is preflight check 3, and the ones that do name
paths get details wrong.

So the first step for any issue is an **Opus 5 planning update**, even when the issue looks complete.
The first two passes proved the point: #0109's Givens said `GitProcess.run(_:at:)` when the label is
`workingDirectory:` — the exact wrong-label class that cost #0116 its clock — and claimed a detached
worktree merely omits `branch`, when it also carries an explicit `detached` line. #0108's criterion
was **unimplementable as written**, because `FixtureRepository` presets `commit.gpgsign=false` and so
a fresh fixture is never in the unset state the issue asked about.

Four corrections across two issues, every one a fact the author had written from memory and believed.
That is the case for the planning role, and it applies to the backlog as much as to new work.

### What "enough detail" means now

An issue is ready when an implementer could follow it without a judgement call. In practice:

- **Name every path in full**, repo-relative. `YardKit/Sources/YardGit/WhereAmI.swift`, not "the
  engine".
- **Paste every signature the round must call**, and the public members of each result type.
- **Paste the literal change** where it is small — the expression, the line, the record layout.
- **State measured before-and-after values**, and say they were measured. `od -c` bytes, real command
  output, actual counts.
- **One deliverable.** If the Expected behavior list has two verbs in it, split it.

The counter-risk is real and has cost rounds: **a code sample written from memory propagates silently**
(#0093, #0114). Everything pasted into an issue must have been run, and the issue must say so.

### A planner commits early and refines in place

**Commit the issue file as soon as it is structurally complete, then keep editing it.** Do not hold
the finished artifact in context until every mutation has been run and commit once at the end.

A round that commits to its branch as it goes leaves something readable behind when it is killed —
which is why an implementation round is told to commit its work before it reports. A planning pass
that commits only at the end has no such property, and the
difference is not theoretical: an API session limit killed a dispatcher and two planners
simultaneously on 2026-08-08. The dispatch resumed from its round commit with nothing lost; both
planners lost the entire pass, including scratch trees whose code had already been compiled and
mutation-tested.

The measurements are the expensive part and they are the last thing produced, so they are exactly
what a late commit puts at risk. Commit the skeleton, then commit again as each block is verified.

### The `swift-guidance` skill is used in all three roles

`~/.claude/skills/swift-guidance` encodes Brennan's expectations for Swift code and project
structure — concurrency and actor isolation, logging, SwiftUI and Observation rules, dark mode,
performance, multiplatform, and build-setting configuration. **Load it, do not work from memory.**

- **Planning** loads it before writing any Swift into an issue. A code block in an issue is
  copied almost verbatim by the implementer, so an anti-pattern there propagates to every round that
  follows. Its `references/project-configuration.md` covers `MainActor` default isolation and strict
  concurrency — the exact ground #0126 turned on.
- **Implementation** loads it before writing the file. It is named in the dispatch prompt.
- **Review** loads it when reading the diff, and reports what it finds as ordinary review findings.

It has a deliberate stopping rule — one or two high-impact issues per area, then stop, no style
nitpicking. Respect that. A review that returns twenty findings is not more thorough, it is unusable,
and it will bury the one finding that mattered.

### Milestone review

When every issue in a milestone is `resolved`, an **Opus 5** subagent reviews the milestone as a whole
against the exit criteria in guide §9 — not issue by issue, which is what per-issue review already
does and cannot substitute for.

It exists because per-issue review is structurally blind to the gaps *between* issues. #0115 is the
proof: forty-two M1 issues passed review individually while the milestone's actual criterion — working
commands — went unmet, and no single issue's review could have seen it.

**Exit criteria live in guide §9, one checklist per milestone — not in an umbrella issue.** An
umbrella issue is a different tool: it breaks *one feature* into several small implementation tasks,
which is how work is sized for a small model. A milestone criterion is a property of the whole
milestone, often spanning features, and frequently satisfied by no single issue. **Opus reviews
umbrella issues** — the parent, once its children resolve — because that is per-feature review and
belongs with the rest of issue review.

Rules that keep it from becoming an open-ended quality pass:

- **It may only file issues against the milestone's stated exit criteria in guide §9.** Not general
  quality, not style, not "this could be better". If a criterion is not in the guide, it is not a
  finding — it is a proposal, and it goes to Brennan.
- Findings become ordinary issues, implemented through the normal loop, and the milestone is reviewed
  again when they resolve.
- **Two consecutive reviews with no findings closes the milestone.** Without a termination rule the
  loop can cycle forever.

**The primary checkout stays on `main`, permanently.** It is the checkout a human watches, and it is
where merged work becomes visible. Never switch it to an issue branch and never run a dispatch in it:
that pins `main`, so every finished issue queues behind whatever round is running while the repo
reads as idle. Issue work happens only in `../switchyard-NNNN` worktrees; merges happen here.

**Record every measurement in the turn it is reported.** A dispatcher subagent reports
`subagent_tokens` exactly once, in a completion notification that exists nowhere else — not in git,
not in a log, not in any API. When the session ends it is gone. Write it into
`issues/cost-ledger.md` and the issue's `## Work log` immediately; do not hold it in conversation
context intending to write it up later. The same applies to wall times, round counts, and any number
the harness surfaces once.

**Push immediately and merge immediately.** Push the branch when it is created and after every
round; squash-merge and push `main` the moment an issue resolves. Do not batch. Work that is
committed but unpushed is invisible, and invisible work is indistinguishable from no work — this has
already happened once, with seven finished branches sitting unpushed while `main` looked idle.

**One round in flight, two at the outside.** The old ceiling of one came from a local host that
degraded under concurrency; that reason is gone, but the policy mostly stands for a better one.
**Review is the bottleneck, and review runs in the main loop.** A second round finishing while the
first is under review does not go faster — it goes unmerged, which is how seven finished branches
once sat unpushed while `main` read as idle. Dispatch a second only when both issues are small,
independent, and the first is already merged or in review. The binding constraint now is the weekly
usage limit, not a machine, so an idle slot costs nothing and a wasted round costs real budget.

Two rules that bind this file specifically:

- **Dispatch through a subagent, never from the main loop.** A round's transcript is long and
  worthless once the outcome is known; the subagent absorbs it and returns a verdict. Keeping the
  main context small is what makes authoring and reviewing good.
- **Branch per issue, squash to `main`.** `git worktree add ../switchyard-NNNN -b issue/NNNN main`,
  one commit per round on the branch, then `git merge --squash` into a single commit on `main`.
  **Never delete the branch** — squash-merging records no ancestry, so the branch is the only
  surviving record of how the work went, and the issue's `**Commit**` row points into it. Removing
  the *worktree* after the merge is right and expected; deleting the branch is not.

## Issue status is part of the work, not bookkeeping after it

The tracker is what a human reads to know what is happening. An issue being
actively dispatched must say so.

**The lifecycle, and who moves it:**

| transition | when | by |
|---|---|---|
| `open` → `in-progress` | **before** dispatching a round | `./scripts/set-issue-status.sh NNNN in-progress` |
| `in-progress` → `resolved` | the round passed review **and** is squash-merged to `main` | the same script |
| `in-progress` → `open` | the 3-round cap was hit, or the issue is being rewritten or split | the same script |
| `in-progress` → `wontfix` | the work turned out not to be worth doing | the same script, and say why in the issue |
| `resolved` → `closed` | **Brennan confirms.** Never set this yourself. | Brennan |

`scripts/set-issue-status.sh` refuses anything outside those five values, and
**`scripts/preflight-issue.sh` refuses to dispatch an issue that is not
`in-progress`** — so claiming it is a gate rather than a habit.

**Resolved means merged, not merely accepted.** A round that passes review but
sits unmerged is still `in-progress`; that is what stops a green branch being
mistaken for landed work.

**Set it back to `open` when a round is abandoned.** An issue stuck at
`in-progress` with nothing running is worse than one marked `open`, because it
reads as claimed and nobody picks it up.

## Learning from failed reviews

**`docs/review-failures.md` is the failure log, and it is read before every dispatch — not after.**
A failed round is only expensive once; paying for the same failure twice is the thing this section
exists to prevent. Two rounds have already been lost to a single sandbox rule because the lesson was
written into a retrospective instead of into the file the model reads.

### Before dispatching any issue — every time, including a re-dispatch

1. **Run `scripts/preflight-issue.sh NNNN`.** It implements every mechanical check derived from a
   past failure, and it is now the *only* automated gate — nothing downstream re-runs it, so a round
   dispatched without it is dispatched unchecked.
2. **Read the `## Preflight checklist` in `docs/review-failures.md`** and answer its `[JUDGMENT]`
   questions against the issue text. These are the ones no script can decide — whether the issue has
   one deliverable, whether every fact it asserts was verified, whether it names a path that can hold
   a tested unit.
3. **If the issue fails any check, do a planning update first.** Rewrite the issue, commit it as its
   own change with a message saying what failure class it is being hardened against, and only then
   dispatch. **Never dispatch an issue you already know is defective** in the hope the model works
   around it — that is how a round gets spent proving something already known.

### When a review fails

A round that exits non-zero, produces no code, or fails review is a **failed review**, and it triggers
this sequence before anything else is dispatched:

1. **Kick off a learning subagent** on the failure. Not optional and not deferred: point it at the
   round log, the issue text, and the existing failure log, and have it return the root cause, the
   failure class, and the preflight check that would have caught it. It must analyze only — no edits.
   Doing this in a subagent keeps the round transcript out of the main context, which is the same
   reason dispatch happens in one.
2. **Record the round in `docs/review-failures.md`** — one row in the failure table, and a new entry
   in the preflight checklist if the cause is not already covered. Do this in the turn the finding
   arrives; see the rule about measurements above, which applies identically here.
3. **Push the fix to where it will be read.** A lesson about the round's behaviour or its environment
   goes into `AGENTS.md` as a numbered rule, because that is the rulebook the dispatch prompt makes
   an implementation round read. A lesson about how
   issues are written goes into the preflight checklist. A lesson that a script can enforce goes into
   `scripts/preflight-issue.sh`. **A finding recorded only in `docs/` has not been fixed** — it has
   been filed.
4. **Then** do the planning update to the issue and re-dispatch.

### Reviewing a round — the two things that have slipped through

**Re-run the verification yourself.** Reading the model's pasted output and agreeing with its
interpretation is not review; #0070 round 1 was accepted that way and was wrong in three places.

**Read the body of every new test, not its name.** Twice now a round has landed a green suite whose
tests assert nothing — a loop over `allCases` that `continue`s past all but one case, and functions
containing no `#expect` at all. Ask what production change would make each test fail. If the answer
is "none", the criterion is not met however green the run was. This is `AGENTS.md` Rule 7 from the
reviewer's side.

### The classes, so a failure gets filed rather than re-derived

`spec-defect` (the issue text was wrong or unbuildable) · `environment` (sandbox, missing tool,
timeout) · `model-behaviour` (narrated instead of acting, looped, fabricated, violated scope) ·
`review-defect` (the reviewer accepted something wrong, or gave feedback that broke the next round) ·
`sizing` (too many deliverables). Most failures so far have been `spec-defect` — which is to say
**most failed rounds are my fault, not the model's**, and the fix belongs upstream of the dispatch.

**`AGENTS.md` is the round's rulebook, and it stands alone.** It was written for a delegate that
could not see this file, and it keeps that property on purpose: it duplicates the licensing and
code-signing rules **inline rather than by reference**, so a round that reads only `AGENTS.md` still
has them. The dispatch prompt names it explicitly; do not assume a subagent has read this file.

**This file stays canonical. Any edit to the licensing or signing rules must be mirrored into
`AGENTS.md` in the same commit** — a delegate operating on a stale copy of the GPL rule is exactly
the failure this project cannot absorb.

## Licensing — read before writing any code

Switchyard is **MIT** (`LICENSE`). Two reference projects sit next to it and they are not
interchangeable.

**GitUp — `../GitUp` — is GPLv3.** Copyright 2015-2018 Pierre-Olivier Latour. GitUpKit too.
Switchyard is a clean-room reimplementation, and MIT output makes this stricter, not looser:

- **Never copy GitUp source into Switchyard**, in any language. A line-by-line Objective-C to Swift
  translation is a derivative work.
- **Never paste GitUp source into the context window and ask for a Swift port.** Same thing, worse.
- **Never copy GitUp's test fixtures**, including the graph-layout DAG fixtures. They are GPL.
- **Do** read GitUp to understand *what a component solves* and *why it is shaped that way*, then
  close the file and design the Swift equivalent independently.
- When a GitUp idea informs a decision, write the idea into `docs/` in your own words and implement
  from that note, not from the source.

If the plan ever becomes "port it," stop and revisit the license with Brennan before writing code.

**RemoteControl — `../../RemoteControl` — is MIT, same author.** Its code may be copied and adapted
freely. Retain the copyright notice where substantial portions are reused. Port the XPC and CLI
install patterns from it directly; do not reinvent them.

## The agent surface

The CLI is the product for agents. Three rules make it usable by one:

- **`--json` on every command, and `"schemaVersion": 1` in every response.** Human-readable output
  is a courtesy; JSON is the contract. Errors are structured too — a failure in `--json` mode emits
  `{"schemaVersion":1,"ok":false,"error":{"code":"…","message":"…","hint":"…"}}` on stdout.
- **Nothing is interactive unless the command name says so.** No editor, no pager, no prompt.
  `GIT_EDITOR` is never invoked. Interactive commands (`review`, `ask`, `resolve --interactive`)
  fail with exit 3 when the app is not running rather than silently falling back — an agent told to
  get human approval must not proceed without it.
- **Exit codes are meaningful.** Codes 2-5 match RemoteControl exactly; do not renumber them.

**There is no MCP server** — decided, with the reasoning and the conditions for revisiting in guide
§8. Do not add one, and do not let anything depend on one existing.

The skill teaching agents to drive `switchyard` lives in `skills/yard/SKILL.md` and is **generated from
the same command metadata that builds `--help`**, so it cannot drift from the binary. Hand-written
prose that restates flags will go stale within a milestone. Package it per client (Claude Code
plugin, OpenCode) on top of that one source; do not maintain parallel copies. A command lands with
its documentation regenerated or it does not land.

## Code signing

**Never modify Apple signing assets.** Do not pass `-allowProvisioningUpdates` or
`-allowProvisioningDeviceRegistration`. Do not create, revoke, delete, or renew certificates or
provisioning profiles — not via `xcodebuild`, `security`, `codesign`, `fastlane`, the App Store
Connect API, or the developer portal. Never delete anything from a keychain. Do not change
`CODE_SIGN_STYLE`, `CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM`, or `PROVISIONING_PROFILE_SPECIFIER` to
make a signing error go away without asking first.

**Build unsigned by default.** Signing is only needed for archives, device installs, and tests that
verify signatures.

**Stop, do not retry, on these stop-words.** `No signing certificate ... found`, `its private key is
not installed in your keychain`, `errSecInternalComponent`, `User interaction is not allowed`, or
any offer to revoke or replace a certificate. Drop to an unsigned build to prove the code compiles,
diagnose read-only, then report and wait.

This is not hypothetical. On 2026-07-24, 52 signed `xcodebuild` runs against RemoteControl — with
Xcode open and automatic signing on — drove `IDEProvisioningRepair` to revoke and reissue the Apple
Development certificate twice. Revocation is remote, account-wide, and irreversible.

**Archives, notarization, and DMG creation are run by a human**, through Xcode's Product → Archive →
Distribute App flow. Prepare commands and hand them over; do not run them. Brennan prefers GUI paths
(Xcode, Keychain Access, Finder, Disk Utility) for anything touching certificates or signing — give
menu paths, not shell.

## Building and testing

```sh
# Unsigned compile check (the default — see above)
xcodebuild build -project Switchyard.xcodeproj -scheme Switchyard \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet

# Unit tests. UI tests cannot run under CLI-driven xcodebuild here — the runner times out
# enabling automation mode without Accessibility rights. Always scope to SwitchyardTests.
xcodebuild -project Switchyard.xcodeproj -scheme Switchyard \
  -destination 'platform=macOS' -only-testing:SwitchyardTests test

# The Swift package (engine, XPC protocols, CLI). Touches no signing assets — prefer it.
cd YardKit && swift build && swift test
```

`YardKit/` exists with four targets — `YardGit`, `YardKit`, `YardUI` and the `switchyard`
executable — and five test targets. See [Current state](#current-state).

## Layering

**Everything lives in the package, including the views.** `YardUI` holds every SwiftUI view and
everything around them; it depends on `YardKit` and `YardGit`, and nothing in the engine imports it.
The Xcode project keeps only what cannot live in a package — the `@main` `App` type, the asset
catalog, `Info.plist`, entitlements, `SMAppService` registration, and the embedded `switchyard`
binary.

The reason is testability, not tidiness: **UI tests cannot run under CLI-driven `xcodebuild` here**,
so a view in the app target is a view nothing can exercise unattended. The same view in a package
target is reachable from `swift test`. Guide §11 decision 10.

`YardUI` sets `.defaultIsolation(MainActor.self)`. A package target does not inherit the app's
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and a view moved across that boundary silently changes
isolation.

**`switchyard` is a companion tool, not a standalone one.** It ships inside the app bundle, is
symlinked into `/usr/local/bin`, and drives Switchyard.app over XPC. **The app owns the engine.**

- **`YardGit` and libgit2 live in the app only.** The CLI does not link them, and does not open a
  repository itself.
- **The CLI marshals arguments over XPC and prints the reply.** It stays small.
- **If the app is not running, the CLI launches it** and polls the broker for an endpoint, bounded,
  exiting 3 when that expires. This is RemoteControl's model — see
  `../../RemoteControl/docs/xpc-cli-architecture.md`, which is the prototype this pattern comes from.

**There is no CI or SSH requirement.** An earlier version of this file called "works without the app"
the most important constraint in the project, and cited CI, SSH and headless agent runs. **That was
never a requirement Brennan set** — it was invented and then treated as settled, which is how it
reached the guide, the README, and the shape of `Package.swift`. Corrected 2026-08-06. Do not
reintroduce it, and be suspicious of any issue whose rationale depends on it.

`ServiceNames.swift` in `YardKit` is the single source of truth for the bundle identifier, Mach
service name, agent plist name, URL scheme, and log subsystem. Nothing else hardcodes those strings.

## Never read `$GIT_DIR` with `FileManager`

Not the refs, not the index, not the reflog. Resolve every git path through
`git rev-parse --git-path` or libgit2. No string concatenation onto `.git/` anywhere in the
codebase. Three things break naive parsing today, independently:

- **Reftable.** It becomes the default ref format for new repositories in Git 3.0. Anything reading
  `.git/refs/**` or `packed-refs` returns nothing at all on such a repo — not an error, nothing.
- **Index format variants.** v4 path compression, split index, untracked cache, fsmonitor.
- **Worktrees.** `HEAD` lives in `$GIT_DIR`, `refs/heads/*` in `$GIT_COMMON_DIR`, and which applies
  depends on the ref name. `refs/bisect`, `refs/worktree`, and `refs/rewritten` are the exceptions
  that are per-worktree despite starting with `refs/`.

The one exception: FSEvents paths used as a "something changed, re-read" signal, never as a source
of truth. Ref changes come from the `reference-transaction` hook, which reports what actually
changed and in what order.

`WorktreeContext` — worktree path, `$GIT_DIR`, `$GIT_COMMON_DIR`, worktree id — is resolved once per
invocation, and every path lookup goes through it. It exists from M1 for this reason.

## Gotchas that have already caused bugs elsewhere

- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** is set on the app target (it already is, in
  `project.pbxproj`). Objective-C callback closures the XPC framework invokes off the main queue —
  `remoteObjectProxyWithErrorHandler`, `interruptionHandler`, `invalidationHandler` — must be marked
  `@Sendable`, or they inherit main-actor isolation and **crash with `SIGTRAP` at runtime with no
  compiler warning**. Pure helpers need explicit `nonisolated` to stay unit-testable.
- **`SMAppService.status` can disagree with launchd.** Drive repair from an actually-failed broker
  call, at most once per launch, rather than trusting the reported status.
- **Keep exactly one copy of the built app on disk.** `SMAppService` registration is keyed to the
  bundle; a DerivedData copy plus one in `/Applications` confuses launchd.
- **`log` is a zsh builtin.** Use `/usr/bin/log stream --predicate 'subsystem ==
  "co.sstools.Switchyard"'`.
- **Xcode rewrites `project.pbxproj` while it has the project open**, and has silently dropped
  hand-added build configurations mid-edit. Verify with `xcodebuild -showBuildSettings` rather than
  trusting the file you just wrote. New Swift files under synchronized groups need no pbxproj edit.
- **`switchyard` never runs `git gc`.** Pruning deletes the journal's anchor ref and metadata entry;
  the objects become unreachable and ordinary maintenance reclaims them on its own schedule.
- **The `reference-transaction` hook fires on the journal's own ref writes.** Set an environment
  marker in `switchyard` and have the hook skip its own transactions, or the journal records itself
  recording itself. **Do real work only on `committed`; return 0 immediately in every other state.**

  The states git 2.50.1 actually emits are **`prepared`, `committed`, `aborted`** — measured, by
  installing a hook that logs `$1` and running a real commit. There is **no `preparing` state**;
  this file and the internals document both named one until 2026-08-07. A non-zero exit in
  `prepared` aborts the user's transaction — also measured: `[ "$1" = prepared ] && exit 1` yields
  `fatal: ref updates aborted by hook`, exit 128, and the ref is never created. Treat any state
  that is not `committed` as do-nothing, so a future git that adds one cannot break a repository.
- **`git write-tree` refuses an unmerged index.** When conflicts are present, snapshot the index
  file itself as a blob and restore it byte-for-byte. That is the one place where reading a git file
  directly is correct, because the file *is* the state.
- **libgit2 does not run hooks.** Silently skipping a repo's hooks is a correctness bug, not a
  simplification. Shell out to `git` for hooks, network operations, and signing — every shell-out
  centralized in one `GitProcess` type so the boundary is visible and testable.

## Current state

**Updated 2026-08-17.** This section was two milestones out of date — it still said the repository was
a stock SwiftUI template with nothing built, which a fresh context would read as fact.

- **M0 is done.** `docs/engine-findings.md` answers all four spike questions with measured evidence
  and the spike code is deleted. Its exit criteria in guide §9 are checked off.
- **`YardKit/` is real**: `YardGit` (46 source files — the engine), `YardKit`, `YardUI`, and the
  `switchyard` executable, plus five test targets. `docs/test-baseline.txt` carries the current suite
  count, and it is the number to trust rather than any figure written into prose here.
- **M1 — the read engine and worktrees — is at its milestone review**, not at its start. The engine
  behind `whereami`, `graph`, `status`, `hunks`, `conflicts`, `log` and `verify` and the whole `wt`
  group exists with tests.
- **M2 — journal, hooks, safe mutation — is the milestone in progress.** The journal, its anchor
  store, undo/redo, the chain, and hook install all exist; see the M2 checklist in guide §9 for what
  is not done.
- **The app target is still a stock SwiftUI template.** Nothing in the XPC layer, the broker, or the
  UI is built; that is M3 onward. An engine with no caller is exactly the gap guide §11 decision 11
  moved to M3.

**On 2026-08-16 `main` was reset** to recover from work done outside the workflow; see
`docs/workflow-reset-2026-08-16.md` for what moved to which branch and what has to be re-done.
