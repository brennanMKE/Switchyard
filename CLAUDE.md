# Switchyard

A SwiftUI macOS git client with an agent-facing CLI (`yard`). Successor in spirit to GitUp, built
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

`/loop` is the harness mechanism for sustained work. `/loop work the next open issue` with no
interval lets the model self-pace; with an interval it re-fires on a schedule. Between firings the
issue tracker is the state — status rows and branches say what is done, so a fresh context resumes
without needing the previous conversation.

## Implementation is delegated to OpenCode running a local model

Implementation work goes to **OpenCode** driving **Ornith 1.0 35B-A3B** (8-bit MLX) locally via
**LM Studio** on `127.0.0.1:1234`. Ornith is a Gemma 4 model tuned using Qwen — an MoE without
thinking, so it is much faster than the dense thinking Qwen it scores close to. That trade suits
implementation work whose thinking already happened when the issue was authored. **It replaces
Sonnet here.** Token cost is $0.00.

**The loop is: Opus or Fable authors the issue in enough detail that implementation needs no further
judgment → a subagent dispatches it → Opus reviews the diff and the real verification output →
accept, or write a `## Review` section into the issue and re-dispatch.** Full workflow, roles, and
loop protection are in `issues/Issues.md`.

**The primary checkout stays on `main`, permanently.** It is the checkout a human watches, and it is
where merged work becomes visible. Never switch it to an issue branch and never run a dispatch in it:
that pins `main`, so every finished issue queues behind whatever round is running while the repo
reads as idle. Issue work happens only in `../switchyard-NNNN` worktrees; merges happen here.

**Ornith's token counts come from `./scripts/ornith-tally.sh`, not from the dispatch logs.** The
logs carry no token counts and LM Studio exposes no historical usage endpoint; OpenCode's SQLite
database at `~/.local/share/opencode/opencode.db` records `tokens_input`/`tokens_output` per session
and is the only durable record. Unlike a dispatcher's `subagent_tokens`, it survives the session, so
it can be regenerated at any time — run it when updating `issues/cost-ledger.md`. Attribution is by
working directory, which is another reason a dispatch must run in `../switchyard-NNNN` and never in
the primary checkout.

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

Concurrency ceiling: LM Studio is configured `PARALLEL 2`, so a third simultaneous dispatch queues
rather than running. Two rounds at a time is the real limit until that is raised.

Two rules that bind this file specifically:

- **Dispatch through a subagent, never from the main loop.** An OpenCode transcript is long and
  worthless once the outcome is known; a subagent absorbs it and returns a verdict. Keeping the main
  context small is what makes authoring and reviewing good, which is what makes the local model
  work at all.
- **Branch per issue, squash to `main`.** `git switch -c issue/NNNN`, one commit per round on the
  branch, then `git merge --squash` into a single commit on `main`. **Never delete the branch** —
  squash-merging records no ancestry, so the branch is the only surviving record of how the work
  went, and the issue's `**Commit**` row points into it.

Run dispatches through `scripts/dispatch-issue.sh NNNN --round N`, which enforces a wall-clock
timeout, a 3-round cap, a clean tree, and the correct branch. It has looped before; the guards are
the mechanism, not the prose.

## Learning from failed reviews

**`docs/review-failures.md` is the failure log, and it is read before every dispatch — not after.**
A failed round is only expensive once; paying for the same failure twice is the thing this section
exists to prevent. Two rounds have already been lost to a single sandbox rule because the lesson was
written into a retrospective instead of into the file the model reads.

### Before dispatching any issue — every time, including a re-dispatch

1. **Run `scripts/preflight-issue.sh NNNN`.** It implements every mechanical check derived from a
   past failure. `dispatch-issue.sh` runs it too and refuses to dispatch on failure, so this is for
   seeing the result while there is still time to fix the issue.
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
3. **Push the fix to where it will be read.** A lesson about the model's behaviour or its environment
   goes into `AGENTS.md` as a numbered rule, because that is what OpenCode loads. A lesson about how
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

**`AGENTS.md` is what OpenCode reads — it does not load this file.** Verified: asked for the GitUp
licensing rule with only `CLAUDE.md` present, the model answered `UNKNOWN`; with `AGENTS.md` present
it recited the rule. `AGENTS.md` therefore duplicates the licensing and code-signing rules inline
rather than by reference.

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

The skill teaching agents to drive `yard` lives in `skills/yard/SKILL.md` and is **generated from
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

`YardKit/` does not exist yet. Until it does, the app target is a stock SwiftUI template — see
[Current state](#current-state).

## Layering

**Everything shareable lives in the package.** The app target owns only SwiftUI views, agent
embedding, `SMAppService` registration, and presentation of results. Anything with logic worth
testing goes in `YardKit` and has unit tests.

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
- **`yard` never runs `git gc`.** Pruning deletes the journal's anchor ref and metadata entry;
  the objects become unreachable and ordinary maintenance reclaims them on its own schedule.
- **The `reference-transaction` hook fires on the journal's own ref writes.** Set an environment
  marker in `yard` and have the hook skip its own transactions, or the journal records itself
  recording itself. The hook must also return 0 immediately in the `preparing` and `prepared`
  states — a non-zero exit there aborts the user's transaction. Do real work only on `committed`.
- **`git write-tree` refuses an unmerged index.** When conflicts are present, snapshot the index
  file itself as a blob and restore it byte-for-byte. That is the one place where reading a git file
  directly is correct, because the file *is* the state.
- **libgit2 does not run hooks.** Silently skipping a repo's hooks is a correctness bug, not a
  simplification. Shell out to `git` for hooks, network operations, and signing — every shell-out
  centralized in one `GitProcess` type so the boundary is visible and testable.

## Current state

The repository is a stock SwiftUI macOS template plus the documents in `docs/` and the tasks in
`issues/`. Nothing in the architecture above is built yet.

**Milestone 0 is the engine spike, and nothing else starts until it lands.** It answers four
questions in `docs/engine-findings.md` — SSH-signed commits through libgit2, graph layout
performance on a 50k-commit repo with and without `commit-graph`, how libgit2 packages into SwiftPM
in 2026, and whether the chosen build can read a `--ref-format=reftable` repository — then the spike
code is deleted. Do not scaffold the app first.

If signing or performance fails, stop and escalate; the project's premise depends on both. A
reftable failure does not stop the project but must be settled before M1, because it moves ref
enumeration and graph traversal onto `git` plumbing, and that is not a retrofit.
