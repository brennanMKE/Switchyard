# Switchyard

Switchyard is a SwiftUI macOS git client with an agent-facing CLI (`yard`), built so a coding agent
is a first-class user of the repository alongside a human. macOS only. This tracker covers the
whole repo: the `YardGit` engine, the `YardKit` package, the `yard` CLI, the app and its broker
agent, the generated agent skill, and the docs. The project is pre-implementation, so most issues
here are **implementation tasks derived from the milestones**, not bug reports — the format bends
accordingly (see "Task issues" below).

This file is the local guide for managing issues in this project. The companion Mac app (Issues.app) watches the `issues/` folder and renders the current state. Markdown files (and `project.json`) are the source of truth — there is no generated artifact or index to keep in sync.

The `# {Project Name}` heading above should match the `name` field in `issues/project.json`. `project.json` is the canonical source for the project's identity (name + repo URL); this guide is the workflow companion.

## Folder layout

```
issues/
├── project.json       # canonical project name + repo URL
├── Issues.md          # this file
├── 0001.md            # one file per issue
├── 0001/              # optional sibling folder for screenshots, crash logs, etc.
│   └── screenshot.png
├── 0002.md
└── …
```

## Project config (`project.json`)

A small JSON file naming the project and its repo. Two required fields:

```json
{
  "name": "{Project Name}",
  "url": "https://github.com/user/repo"
}
```

- `name` — the project's human-readable name. Match the heading at the top of this file.
- `url` — the project's canonical web URL (HTTPS form, not SSH). Typically a GitHub URL; GitLab, Bitbucket, etc. work too.

When the repo moves or renames, edit `project.json` directly. Don't infer the project's name from the parent folder path — `project.json` is authoritative.

## Status values

| File value | Display name | Meaning |
|---|---|---|
| `open` | Open | Filed but not yet started |
| `in-progress` | In Progress | Actively being worked on |
| `resolved` | Resolved | Work is done; awaiting user confirmation |
| `closed` | Closed | User has confirmed the fix |
| `wontfix` | Won't Fix | Acknowledged but won't be addressed |

Use the **file value** (lowercase, hyphenated) in the issue's metadata table. The Mac app converts to the display name when rendering.

## Critical rule: never close without explicit confirmation

The most important rule of this workflow: an issue must **never** be marked `resolved`, `closed`, or `wontfix` based on inference. Only when the user has said so in plain language. Specifically, do not infer resolution from:

- a code change you (or a subagent) just made
- a commit message
- the filing of a related issue
- the user saying "thanks, that looks better"

Leave status at `open` (or `in-progress` if work has started) until the user confirms in words like "close this", "this is fixed", "mark resolved", or "won't fix". When in doubt, ask.

The deliberate exception: a subagent that finishes a fix may set `resolved` (work-is-done-but-not-confirmed). It must not set `closed` — that's the user's call. This separation is the entire reason `resolved` and `closed` are different states.

## Git tracking

This project's choice on whether `issues/` is in git determines whether lifecycle events produce commits. Check on every operation:

```bash
git rev-parse --is-inside-work-tree 2>/dev/null   # is this a git repo?
git check-ignore -q issues/                        # exit 0 = ignored, 1 = tracked
```

- **Not a git repo, or `issues/` is ignored**: edit files only; never commit. The Mac app still tracks changes from the working copy.
- **`issues/` is tracked**: each lifecycle event below produces its own commit.

`issues/` **is tracked** in this project. Note that this project also uses a branch per issue — read
"Branching and merging" below before committing anything, because where a commit lands matters as
much as what it says.

| Event | Where | What's committed | Commit message |
|---|---|---|---|
| File a new issue | `main` | the new `NNNN.md` | `#NNNN <issue title>` |
| Edit project config | `main` | `project.json` only | `Update project config` |
| Round of implementation work | `issue/NNNN` | that round's code changes | `#NNNN round N: <what it did>` |
| Resolve — mark it done | `issue/NNNN` | markdown update (status, Closed, Commit, Branch, summary, work log) | `#NNNN Resolve: <title>` |
| Land it | `main` | everything, squashed | `#NNNN <issue title>` |
| Bail with notes | `issue/NNNN` | markdown only | `#NNNN Notes: <brief>` |
| User-confirmed close | `main` | markdown only | `#NNNN Close` |
| Won't fix | `main` | markdown only | `#NNNN Won't fix` |

Filing a batch of issues at once — seeding a backlog — is one commit, not one per issue. The
per-issue commit convention exists to record a lifecycle, and a backlog authored in a single pass
does not have one yet.

**Working-copy-only changes (no commit):**

- Setting status to `in-progress` at the start of work — transient; the resolve commit supersedes it.

**Which hash goes in the `**Commit**` row.** Under squash-merging, the work lands on `main` as a
single new commit whose hash cannot exist until after the merge — so it cannot be written into the
markdown that the merge is squashing. The row therefore records **the last code commit on
`issue/NNNN`**, and a `**Branch**` row records the branch. That hash is durable precisely because
**the branch is never deleted**. `main` answers "what changed for this issue"; the branch answers
"how did it go", and the metadata rows point at both.

## Issue file format

Each issue is `NNNN.md` (4-digit zero-padded) with this structure:

```markdown
# NNNN — Title

| | |
|---|---|
| **Status** | open |
| **Module** | <module name(s)> |
| **Platform** | iOS · macOS · iPadOS · All |
| **First seen** | YYYY-MM-DD |

## Description

What is wrong. Lead with the punchline — the first paragraph shows in the Mac app summary.

## Steps to reproduce

1. …
2. …

## Expected behavior

What should happen.

## Actual behavior

What actually happens.

## Attachments

![caption](NNNN/screenshot.png)

## Notes

Any additional context, guesses at root cause, related code locations.
```

### Task issues

Most issues in this project are implementation tasks rather than bug reports, so:

- A **`**Milestone**`** row is added to the metadata table (`M0`–`M5`, or `—` for cross-cutting
  work). Milestones are defined in `docs/switchyard-development-guide.md` §9 and are ordered:
  nothing in M1 starts before M0 lands.
- **`## Description`** says what to build and why it matters.
- **`## Expected behavior`** is the done-criteria checklist. An issue is not resolvable until every
  box is genuinely true — and per the verification rule below, "it compiles" is never one of them.
- **`## Steps to reproduce`** and **`## Actual behavior`** are omitted; they mean nothing for a task.
- **`## Notes`** carries dependencies (`Blocked by #NNNN`) and the authoritative doc section.

Real bugs found later use the standard bug shape with all sections.

### Work log

Every resolved issue ends with a `## Work log` section recording who did the work and what it cost:

**Cost is recorded per phase, not per issue.** There are three phases and only one of them is ever
free:

```markdown
## Work log

| Phase | Who | Cost |
|---|---|---|
| **Authoring** | Opus | hosted |
| **Implementation** | OpenCode / ornith-1.0-35b-mlx-oq8 (local) | $0.00 |
| **Review** | Opus | hosted |

| | |
|---|---|
| **Rounds** | 2 |
| **Wall time** | 14m |
```

**Authoring and review are always hosted and always cost money.** Writing an issue detailed enough
that implementation needs no further judgment is real work, and so is reading a diff and its
verification output against the done-criteria. Recording those as free would make delegation look
cheaper than it is and would hide where the remaining spend actually goes.

**Implementation is $0.00 only when it actually ran locally.** When a round is taken over by hand —
or by a hosted model for any reason — that row reads `Opus, hosted`, not `$0.00`. The table exists so
a reader can tell at a glance which issues were genuinely free to implement and which were not, so
misattributing one destroys the only thing it is for.

Give a token or dollar figure where one is genuinely known; write `hosted` where it was not
separately metered. **Never invent a number** — an unmetered phase is honestly unmetered.

**Rounds** is how many dispatches it took to converge, and it is the most useful number here: an
issue that took three rounds was underspecified when it was authored, which is feedback about the
authoring rather than about the model. **Wall time** matters because local inference trades money for
time, and that trade can only be judged with both numbers present.

### Format details that matter

- **Title separator** is an em-dash (U+2014, `—`), not a hyphen.
- **Metadata field rows** must keep the field name in `**bold**` exactly.
- **Dates** are `YYYY-MM-DD`.
- **Module** can list multiple modules separated by ` / ` (e.g. `BlueskyFeed / BlueskyDataStore`).
- **Platform** is `iOS`, `macOS`, `iPadOS`, `All`, or any other string. `All` is treated as matching every platform filter.
- When status moves to `resolved` or `closed`, add a `**Closed**` row with today's date. When the move to `resolved` is the result of a fix commit, also add a `**Commit**` row with the short hash of the last code commit on the issue branch, and a `**Branch**` row naming it (`issue/NNNN`). See "Which hash goes in the Commit row" above.
- Steps / Expected / Actual / Attachments / Notes are conventional but not all required — for design-refinement or feature-gap issues, Description alone is fine.

## Filing a new issue

1. Confirm `issues/project.json` exists. If missing, create it (see schema above) before filing the first issue — `name` should match this guide's heading; `url` is the project's canonical web URL (HTTPS, not SSH).
2. Find the highest existing `NNNN.md` and increment. Start at `0001` if the folder is empty. Skip past reserved high numbers (e.g. `8888`, `9999` for test issues).
3. Create `issues/NNNN.md` from the template.
4. Set status to `open`.
5. Use today's date for First seen.
6. Phrase the title as a single declarative sentence describing the bug, not a question or a fix description.
7. **If `issues/` is tracked by git**, commit the new file with message `#NNNN <issue title>` so the issue enters git history with its `open` status. If ignored, skip.

## Updating an issue

Edit the file in place. The Mac app picks up changes automatically — no follow-up command. Touch only the rows or sections that changed; don't reformat the rest.

When status moves to `resolved` or `closed`, add a `**Closed**` row with the date. When the move to `resolved` was driven by a fix commit, also add a `**Commit**` row with the short hash. For any move toward `resolved`, `closed`, or `wontfix`, the "Critical rule" near the top of this file applies — those transitions require explicit user confirmation, not inference.

## The implementation workflow: author → dispatch → review → re-dispatch

Implementation is delegated to **OpenCode** driving **Ornith 1.0 35B-A3B** (8-bit MLX) locally
through **LM Studio**. Token cost is $0.00. The cost is wall time.

**Why this model.** Ornith is a Gemma 4 model tuned using Qwen. It scores nearly as well as the Qwen
model while being an MoE without thinking, where Qwen is dense and thinking and therefore much
slower. Fast and non-thinking is the right trade for implementation work that has already been
thought through — which is exactly what this workflow produces: the thinking happens when the issue
is authored, not when it is implemented. **Ornith replaces Sonnet in this project**; a hosted
mid-tier model is no longer in the loop.

This is also a deliberate experiment in running local AI alongside Claude Code, so treat friction as
a finding worth recording rather than an annoyance to route around.

### The four roles

| Role | Who | Does |
|---|---|---|
| **Author** | Opus or Fable | Writes the issue with enough detail that implementation needs no further judgment: exact files, exact approach, exact verification command, exact done-criteria. |
| **Dispatcher** | A Claude Code **subagent** | Runs `scripts/dispatch-issue.sh` and returns only the outcome. |
| **Implementer** | Ornith, via OpenCode | Implements one issue. Does not commit. Does not set status. |
| **Reviewer** | Opus | Reads the diff and the verification output, then either accepts, or writes a `## Review` section into the issue and re-dispatches. |

**Dispatch through a subagent, not from the main loop.** An OpenCode run produces a long transcript
that is worthless once the outcome is known. A subagent absorbs it and returns a short verdict, which
is what keeps the main context window small enough to keep authoring and reviewing well. This is the
main reason the workflow is shaped this way.

### The loop

0. **Never work in the main checkout.** Every issue gets its own worktree:
   `git worktree add -b issue/NNNN ../switchyard-NNNN main`. This keeps `main` free so a finished
   issue can be merged immediately instead of queueing behind a running dispatch.
1. **Branch and push it empty, immediately**: `git push -u origin issue/NNNN`. A branch that exists
   only locally is invisible, and invisible work looks like no work.
2. **Author** the issue, or update it with review feedback in a `## Review` section.
3. **Dispatch**: a subagent runs `scripts/dispatch-issue.sh NNNN --round N`.
4. **Review** the diff and the pasted verification output — not the model's summary of them.
   **Re-run the verification yourself.** A round that pastes real command output can still be wrong
   about what the output means, and a well-written document is the easiest kind to under-review. On
   #0070 round 1 the model genuinely ran `git interpret-trailers`, and the document still asserted
   three false things about git — caught only because the dispatcher re-ran the checks independently
   rather than reading the prose and agreeing with it.
5. **Commit the round to the branch and push it.** Every round that produced something worth
   reading becomes a commit, including rounds later corrected — that history is the artifact. **Push
   after every round**, so progress is visible while it happens rather than only at the end.
6. **Accept** and merge (below) **or** write `## Review` feedback and go to step 3 with `--round N+1`.
7. **Merge and push the moment an issue resolves.** Do not batch merges. One issue landing on `main`
   is the unit of visible progress, and a queue of finished-but-unmerged branches reads exactly like
   no progress at all.
8. **Escalate** at round 4. The cap is not a suggestion.

```sh
# once, at the start — own worktree, pushed immediately
git worktree add -b issue/0012 ../switchyard-0012 main
cd ../switchyard-0012 && git push -u origin issue/0012

lms ps                                  # confirm the model is loaded
scripts/dispatch-issue.sh 0012          # round 1 (via a subagent, backgrounded)
git add -A && git commit -m "#0012 round 1: <what it did>" && git push

scripts/dispatch-issue.sh 0012 --round 2
```

### Branching and merging

**One branch per issue: `issue/NNNN`. `main` is never worked on directly.**

The branch accumulates a commit per round, and **those commits are kept**. They are the record of
how the work actually went — what the model tried, what review sent back, what finally worked — and
that record is worth more later than a tidy history is now. Do not rebase them away.

**Merge back to `main` as a single squashed commit per issue:**

```sh
# from a worktree on main — never from the issue's own worktree
cd ../switchyard-main
git merge --squash issue/0012
git commit -m "#0012 <issue title>"     # one commit on main, per issue
git push origin main                    # immediately, not batched
git push origin issue/0012              # keep the branch — it is the artifact
```

Keep a dedicated `../switchyard-main` worktree checked out on `main` for exactly this. `main` must
never be the branch a dispatch is running on, or every finished issue waits for that round.

So `main` reads as one commit per issue, while `issue/NNNN` preserves the rounds behind it. **Do not
delete the branch after merging**, locally or on the remote. `git merge --squash` leaves no merge
ancestry, so the branch is the only place that history survives.

Reference the issue number in both the branch name and the squashed commit subject, so the three
records — `main`, the branch, and `issues/NNNN.md` — can always be lined up.

### Loop protection

The model has gotten stuck in loops, so this is enforced by the script rather than by instruction:

- **Wall-clock timeout**, default 1800s, killed hard. There is no `timeout` binary on this Mac, so
  the script runs a watchdog itself.
- **Round cap of 3.** A fourth round requires `--force` and a reason. Three failed rounds means the
  issue is underspecified or too large — fix the issue, do not spend another round.
- **Clean-tree precondition**, so each round's diff is attributable to that round.
- **No-progress detection.** A run that exits successfully and changes nothing exits 7 and is a
  failed round. Never re-dispatch an unchanged prompt after a no-op — it will do the same thing.
- **The model is told to stop rather than retry** a failing action, and that a clear stop is a good
  outcome. Rewarding the report is how you avoid thrashing.

Logs land in `.switchyard-runs/NNNN-roundN.log`, which is gitignored.

### Why the implementer does not commit, branch, or resolve

Ornith leaves changes in the working tree on a branch someone else created. Review decides what
happens to them: commit the round to the branch as an artifact, or discard it with `git checkout .`
when it produced nothing worth keeping. A no-op round is discarded, not committed.

This keeps the critical rule at the top of this file intact — status moves are never inferred from a
code change — and it means the implementer cannot accidentally land work on `main`, squash away the
round history, or mark its own work done.

### AGENTS.md is what OpenCode actually reads

**OpenCode loads `AGENTS.md` into its system prompt. It does not load `CLAUDE.md`.** This was
verified, not assumed: asked to state the GitUp licensing rule with only `CLAUDE.md` present, the
model answered `UNKNOWN`; with `AGENTS.md` present it recited the rule correctly.

So `AGENTS.md` duplicates the two non-negotiable rule sets — the GPL/MIT clean-room separation and
the code-signing prohibitions — inline rather than by reference, because a pointer is not reliable
enough when the failure mode is a legal problem or an account-wide certificate revocation.
**`CLAUDE.md` stays canonical; any change to those rules must be mirrored into `AGENTS.md` in the
same commit.**

### What is not delegated

Some work stays with a human or a hosted model, because the cost of getting it wrong is not a bug:

- **Anything touching the clean-room boundary** — #0015, #0025, #0027, #0060, #0075. A model that
  reaches for GitUp's source or fixtures creates a licensing problem that a code review will not
  reliably catch, since the output looks like ordinary Swift.
- **Anything touching signing, certificates, or archives.** Rule 2 in `AGENTS.md`.
- **The M0 spikes** (#0001–#0005). They are judgment and written findings, not code, and a wrong
  answer here mis-sequences the entire project.
- **Marking an issue `resolved`.** A delegated run reports what it did; verification is confirmed
  independently before status moves. The critical rule above is not delegable.

Good delegation targets are the opposite: self-contained, precisely specified, with done-criteria
that a test can settle. Most of M1's read commands qualify once #0006 lands.

## Resolving an issue: the mechanics

This is the detail behind steps 4–7 of "The loop" above. The roles there apply: Ornith implements,
the reviewer owns everything below.

### Orchestrator: pick and dispatch

1. List `issues/*.md` (skip `Issues.md`). Pick the lowest-numbered file whose status is `open` and
   whose blockers (`Blocked by #NNNN` in its Notes) are resolved.
2. `git switch -c issue/NNNN` from an up-to-date `main`.
3. Spawn a fresh **dispatcher subagent** that runs `scripts/dispatch-issue.sh NNNN --round N` and
   returns only the outcome — the diff summary, the verification output, and whether it converged.
   The subagent exists to absorb the OpenCode transcript so it never reaches the reviewing context.
4. Review, then either land it or re-dispatch with feedback. Move to the next issue when done.

If the user names a specific issue ("fix 0046"), skip the picking step.

### Reviewer: verify → commit → resolve → land

1. **Orient in the project.** Read these in order, every time:
   - **`issues/Issues.md`** (this file) — status vocabulary, module conventions, build/verify command, commit conventions, project-specific rules. **Authoritative for issue-tracking workflow.**
   - **`CLAUDE.md`** at the repo root — project-wide guidance, code conventions, restricted areas, build/test commands. **Treat its instructions as binding.**
   - **`issues/NNNN.md`** — the issue in full, including attachments in `issues/NNNN/`.

   If the two project guides disagree, prefer `CLAUDE.md` for code/repo conventions and this file for issue-tracking specifics.

2. **Set status to `in-progress`** in the markdown — working copy only, no commit.
3. **Review the round's changes.** Read the diff and the verification output the run actually
   printed, not its summary of them. A run that reports success while `git diff` is empty, or that
   describes tests it cannot show output for, failed — send it back or take it over.
4. **Build *and* run the project's verification command, and confirm tests actually executed and passed.** This step is mandatory and cannot be shortcutted.

   - **Compilation is not verification.** "It builds" / "it compiles" / "no type errors" does not count. Tests must actually run — unit tests execute, UI tests run on a simulator, the app launches, whatever the project defines as proof. A green build with zero tests run is a failure of this step.
   - **If you wrote or modified tests as part of the fix, you MUST execute those specific tests and observe them pass.** Confirm the test names you added appear in the run output, the counts increased, and the result was success. A test that compiles but never ran proves nothing.
   - **Read the output, don't just check the exit code.** "0 tests run", "skipped", "no tests found", or a "build succeeded" line with no test summary are red flags even when the exit code is 0. iOS in particular will report `xcodebuild` success when no tests actually executed.
   - **If verification cannot be run in your environment** (no simulator, missing credentials, hardware required, sandbox), you have not verified the fix. Do not mark the issue `resolved` — bail per "When the subagent can't finish" below, naming the verification step you couldn't run.
   - **If the build was already failing before you started**, note it on the issue and bail — don't fix unrelated breakage.

5. **Commit the round to `issue/NNNN`.** Stage *only the code changes* (not the issue markdown yet).
   The message starts with `#NNNN` and a short, declarative title — pick the verb that actually fits
   (`Fix`, `Add`, `Refactor`, `Update`, `Remove`); not every issue is a bug fix. For an intermediate
   round, say which round it was. Leave a blank line after the title, then a paragraph of details:

   ```
   #0046 round 2: wire avatar tap to profile navigation

   Round 1 threaded the DID through the cell but never connected the
   gesture. This adds the NavigationLink and the onTapGesture binding.
   ```

   These per-round commits stay on the branch permanently. Do not rebase or amend them tidy — the
   sequence is the record of how the work went, which is the whole reason the branch is kept.

6. **Capture the commit hash** with `git rev-parse --short HEAD`. This is the last code commit on the
   branch, and it is what the `**Commit**` row records — not a hash on `main`, which will not exist
   until after the squash.

7. **Update the issue markdown** to mark it resolved. **Precondition:** step 4 actually executed and passed. If it didn't, bail — don't resolve.

   - Change Status to `resolved`.
   - Add a `**Closed**` row with today's date.
   - Add a `**Commit**` row with the short hash from step 6.
   - Add a `**Branch**` row naming `issue/NNNN`.

   Then add a structured summary in this order so the issue becomes a primary-source record:

   - **`## Root cause`** — what was actually wrong (often different from the original report).
   - **`## Fix`** — the approach taken.
   - **`## Verification`** — the exact command(s) run and what was observed (e.g. "`xcodebuild test -scheme MyAppUITests` — 14 tests passed including the 3 new tests in `ReplyButtonUITests`"). If new tests were added, name them and confirm they ran. Mandatory — this is the audit trail that distinguishes "verified" from "compiled and hoped".
   - **`## Files changed`** — bulleted list, one bullet per file, with a short note describing what changed in each.
   - **`## Gotchas`** *(optional)* — surprises, dead ends, non-obvious behavior, or anything a future engineer working on similar code should know. Skip if nothing is notable. Be specific — these notes accumulate across issues and feed future "common pitfalls" docs.
   - **`## Work log`** — agent, model, token cost, wall time. See "Work log" above. Local runs record `$0.00`.

8. **Make the resolution commit, still on `issue/NNNN`.** Stage `issues/NNNN.md` and commit with
   message `#NNNN Resolve: <title>`. The body notes which code commit it pairs with (the hash from
   step 6).

9. **Land it on `main` as one squashed commit**, then push both:

   ```sh
   git switch main
   git merge --squash issue/0046
   git commit -m "#0046 <issue title>"
   git push origin main
   git push origin issue/0046      # keep the branch — it is the artifact
   ```

   **Never delete the branch.** `git merge --squash` records no merge ancestry, so once the branch is
   gone the round history is unrecoverable and the `**Commit**` row points at nothing.

Status flow: `open` → `in-progress` → `resolved`. **Never set `closed`** — the user does that after verifying the fix.

### Build / verify command for this project

**Read `CLAUDE.md` at the repo root first — its code-signing rules are binding and non-negotiable.**
Never pass `-allowProvisioningUpdates`, never touch certificates or keychains, and stop rather than
retry on any signing stop-word.

```sh
# Package tests — the primary suite. Touches no signing assets, so prefer it.
cd YardKit && swift build && swift test

# App unit tests. UI tests cannot run here — the runner times out enabling automation mode.
xcodebuild -project Switchyard.xcodeproj -scheme Switchyard \
  -destination 'platform=macOS' -only-testing:SwitchyardTests test

# Unsigned compile check
xcodebuild build -project Switchyard.xcodeproj -scheme Switchyard \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet
```

`YardKit/` does not exist until #0006. Until then, verification for an issue is whatever that issue
names in its Expected behavior — usually a written finding in `docs/`.

Project-specific verification rules:

- **Engine work must be verified against both ref formats.** Fixture repos are built with the
  default format *and* `git init --ref-format=reftable`. A test suite that only ran against one has
  not verified the fix.
- **Journal work must be verified by a real round trip** — mutate, undo, assert the repository is
  byte-identical to the pre-state including refs, index, and worktree. Not by reading the code.
- **XPC work cannot be verified by unit tests alone.** Use the manual verification script (#0054)
  and say in `## Verification` which scenarios were exercised.

### When an issue can't be finished

If the work is out of scope, the build won't pass after reasonable effort, or three rounds have not
converged:

1. **Commit whatever is worth keeping to `issue/NNNN`**, or discard it if it is not. Do not leave
   half-done work uncommitted in the tree — the next dispatch will refuse to start on a dirty tree.
2. **Revert status to `open`** so the issue goes back into the queue.
3. **Add a `## Notes` section** describing what was tried, why work stopped, and what you'd try next.
   Be specific: which rounds, what failed each time, what the next author should change about the
   issue itself.
4. **Commit the markdown** on the branch with message `#NNNN Notes: <one-line bail summary>`.
5. **Leave the branch in place, unmerged.** It is the record of the attempt, and it is where the next
   attempt starts.

Three failed rounds is information about the issue, not just about the model. Rewrite it with more
specific guidance or split it before dispatching again — re-dispatching an unchanged issue produces
an unchanged result.

Never use `wontfix` or `closed` to escape a stuck issue.

## Attachments

Screenshots, crash logs, console output, sample data, etc. live in a sibling folder `issues/NNNN/`. Reference them with paths *relative to the issue's `.md` file* — that means the folder prefix `NNNN/` is part of the link target. The bytes that ship are `1335/screenshot.png`, not `screenshot.png` and not `issues/1335/screenshot.png`.

```
issues/1335.md           ← the markdown that contains the link
issues/1335/screenshot.png   ← the file being linked

# inside 1335.md the link reads:
![caption](1335/screenshot.png)
```

Concrete example with both image and video attachments:

```markdown
## Attachments

![Reply button does nothing when tapped](1335/screenshot.png)
![Crash log](1335/crash.log)
[![Sidebar resize jitter](1335/sidebar-resize-jitter.poster.png)](1335/sidebar-resize-jitter.mov)
```

### Videos (`.mov`, `.mp4`, etc.)

Videos can't be embedded as `![…](…)` — markdown renderers treat that as an `<img>` and a `.mov` won't load. Instead, generate a poster frame with `qlmanage` and emit an image-inside-a-link (shown in the example above). Quick recipe — copy the video into `issues/NNNN/` first, then:

```bash
qlmanage -t -s 1280 -o issues/NNNN issues/NNNN/<basename>.<ext>
mv issues/NNNN/<basename>.<ext>.png issues/NNNN/<basename>.poster.png
```

`qlmanage` ships with macOS — no install. It reliably produces posters for AVFoundation-supported formats: `.mov`, `.mp4`, `.m4v`, `.qt`. For `.avi` it usually works; for `.mkv` and `.webm` it generally fails on stock macOS unless a third-party Quick Look generator is installed. If the rename step doesn't produce the `.poster.png`, fall back to the plain `![alt](NNNN/file.mov)` form with a `<!-- poster generation failed -->` HTML comment in the Attachments section. Don't apply the link wrapper to plain images, and don't generate posters for animated GIFs.

### macOS screenshot / screen recording filename gotcha

macOS Screenshot and Screen Recording filenames both use a **narrow no-break space** (U+202F) before AM/PM, visually identical to a regular space. A literal `cp` of the quoted filename will fail with "No such file or directory". Use a glob to skip past it:

```bash
mkdir -p issues/NNNN
cp ~/Desktop/Screenshot\ YYYY-MM-DD\ at\ H.MM.SS*PM.png issues/NNNN/screenshot.png
cp ~/Desktop/Screen\ Recording\ YYYY-MM-DD\ at\ H.MM.SS*PM.mov issues/NNNN/recording.mov
```

The `*` matches the U+202F. Substitute the actual timestamp; if you don't know which file the user means, list `~/Desktop/Screenshot*` or `~/Desktop/Screen\ Recording*` by mtime and pick the most recent.

## Module conventions for this project

| Module | Covers |
|---|---|
| `YardGit` | The engine: object model, DAG, index, diff, journal, worktree context, `GitProcess` |
| `YardKit` | Shared package library: XPC protocols, message types, `ServiceNames`, `CLIInstaller` |
| `yard` | The CLI executable: command surface, JSON contract, exit codes |
| `Switchyard` | The macOS app target: SwiftUI views, `AppXPCServer`, registration, menu actions |
| `BrokerAgent` | The launch-agent bootstrap broker |
| `Skill` | The generated agent skill and its per-client packaging |
| `Docs` | Design documents and findings under `docs/` |
| `Build` | Xcode project structure, run-script phases, release scripting |

Platform is `macOS` for everything in this project.

## Licensing rule that applies to every issue

GitUp (`../GitUp`, relative to the repo root) is **GPLv3**; Switchyard is **MIT**. Never copy GitUp
source, in any language, including line-by-line Objective-C to Swift translation, and never copy its
test fixtures. Read it to understand a problem, then close it and write your own. RemoteControl
(`../../RemoteControl`) is MIT by the same author and *may* be copied freely. Full rules in
`CLAUDE.md` and `docs/switchyard-development-guide.md` §2.
