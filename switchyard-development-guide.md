# Switchyard

A SwiftUI Mac git client with an agent-facing CLI. Successor in spirit to GitUp, built for a
world where a coding agent is a first-class user of the repository alongside a human.

This document is the development guide. It defines scope, architecture, naming, and the CLI
surface. It is not a task list. Work is sequenced in [Milestones](#9-milestones).

---

## 1. What this is

Two products and a skill, one engine:

| Product | What it is |
| --- | --- |
| **Switchyard.app** | SwiftUI macOS app. Interactive commit graph, three-way merge, review UI. |
| **`yard`** | CLI. Structured, non-interactive git operations for humans and agents. |
| **The `yard` skill** | Generated markdown teaching an agent the command set, packaged per client. |

The name is a railyard: commits are cars, and the app's job is shunting them into a different
order safely. Every mutating operation is reversible.

### Goals

1. **Structured repository state in one call.** Agents currently spend four or five `git`
   invocations and fragile text parsing to answer "where am I." One call, one JSON object.
2. **Journaled undo.** GitUp's most valuable property. An agent whose work can be undone is an
   agent you can let run unsupervised.
3. **Human-in-the-loop over XPC.** An agent can push a diff or a question into a real macOS UI,
   block on a human decision, and receive the answer as structured data. No other git tooling
   does this. It is the differentiator, and it is only possible because of the RemoteControl
   pattern.
4. **Modern git.** Commit signing (SSH and GPG), which GitUp never implemented.

### Non-goals for v1

- Cross-platform. macOS only.
- A general-purpose libgit2 binding. Only the subset Switchyard needs.
- Replacing `git` on the network path. Fetch, push, and credential helpers shell out.
- A hosting-provider integration layer (PRs, issues, CI status). Later, if ever.
- Sandboxing. Same reasoning as RemoteControl: a sandboxed app can only own Mach service names
  prefixed with an app-group identifier, which changes the naming scheme throughout.

---

## 2. Licensing constraint, read this first

**GitUp is GPLv3.** <cite index="20-1">GitUp is copyright 2015-2018 Pierre-Olivier Latour and available under the GPL v3 license.</cite>
That applies to GitUpKit as well.

Switchyard is a clean-room reimplementation. The local GitUp clone is a reference for
**concepts and algorithms**, not a source of code.

Rules, and they are not negotiable:

- **Do not copy GitUp source into Switchyard**, in any language, including line-by-line
  translations from Objective-C to Swift.
- **Do not paste GitUp source files into the context window and ask for a Swift port.** That is a
  derivative work regardless of how it is phrased.
- **Do** read GitUp to understand *what problem a component solves* and *why it is shaped that
  way*, then close the file and design the Swift equivalent independently.
- When a GitUp idea informs a design decision, record the idea in a design note in `docs/`, in
  your own words. Implement from the note, not from the source.
- **Switchyard is MIT.** See `LICENSE`. This is decided, and it makes the separation above strict
  rather than optional — MIT output cannot carry GPL-derived code.
- **RemoteControl is MIT, by the same author.** Its code may be copied and adapted freely; retain
  the copyright notice where substantial portions are reused. The two reference repos next to this
  one have opposite rules, and confusing them is the most likely way this project acquires a
  licensing problem.

If the intended relationship to GitUp ever becomes "port it," stop and revisit the license
question with Brennan before writing code.

### What to study in the GitUp clone

GitUpKit is organized as two layers communicating only through public APIs. <cite index="16-1">The base layer depends on Foundation only: `Core/` wraps a minimal subset of libgit2 and reimplements the rest of the git functionality on top of it, and `Extensions/` adds convenience categories built only on the public APIs. The UI layer depends on AppKit: `Interface/` holds low-level view classes such as `GIGraphView`, `Utilities/` holds interface utilities, `Components/` holds reusable single-view controllers, and `Views/` holds higher-level multi-view controllers.</cite>

Two things are worth understanding deeply:

- **The snapshot and undo system** (`GCSnapshot` and the live repository layer). <cite index="19-1">GitUp tracks semantic operations at the repository state level rather than keeping a simple command history, creating lightweight snapshots before destructive operations so a rollback does not lose work.</cite> This is the model Switchyard's journal should follow.
- **The graph layout engine** (`GIGraph`, plus its test fixtures). Lane assignment for a commit DAG is a genuinely non-trivial algorithm and GitUp's is well tested. Understand the approach, write your own.

Also note that <cite index="16-1">GitUp uses a slightly customized fork of libgit2 and reimplements a great deal on top of a minimal subset of it, including its own rebase engine.</cite> Expect to need a rebase engine too. Stock libgit2 rebase is not sufficient for interactive-style history rewriting.

---

## 3. Naming and identifiers

Follow the RemoteControl conventions exactly, substituting the new name.

| Thing | Value |
| --- | --- |
| App display name | Switchyard |
| App bundle identifier | `co.sstools.Switchyard` |
| Mach service name | `co.sstools.Switchyard.broker` |
| Launch agent plist | `co.sstools.Switchyard.broker.plist` |
| URL scheme | `switchyard://` |
| CLI binary | `yard` |
| Install location | `/usr/local/bin/yard` (symlink into the bundle) |
| Shared package | `YardKit` |
| Broker executable | `BrokerAgent` |
| Log subsystem | `co.sstools.Switchyard` |

`ServiceNames.swift` in `YardKit` is the single source of truth for all of the above. Nothing
else hardcodes any of these strings.

---

## 4. Architecture

```
Switchyard.xcodeproj
├── Switchyard/          macOS app target (SwiftUI)
│   ├── AppXPCServer, URLSchemeHandler, AgentRegistrar
│   ├── Graph view, diff/merge UI, review sheets
│   └── CLIInstallActions (File menu wiring)
├── BrokerAgent/         launch agent executable, bootstrap broker only
├── YardKit/             Swift package
│   ├── YardGit          the engine: object model, DAG, index, diff, journal
│   ├── YardKit          XPC protocols, message types, ServiceNames, CLIInstaller
│   ├── yard             CLI executable
│   └── Tests
├── Support/             Info.plist, entitlements, agent launchd plist
├── skills/yard/         SKILL.md (generated) + hand-written workflow prose, and the
│                        per-client packaging for Claude Code and OpenCode
├── scripts/             make-release.sh, generate-skill.sh
└── docs/                design notes, including clean-room notes on GitUp concepts
```

### The layering rule

**Everything shareable lives in the package.** The app target owns only: SwiftUI views, agent
embedding, `SMAppService` registration, and the presentation of results. Anything with logic
worth testing goes in `YardKit` and has unit tests. This is the BattyKit and BridgeKit principle
carried forward.

### The critical constraint: `yard` must work without the app

This is the single most important architectural decision in the project.

If `yard` requires Switchyard.app to be running, the CLI is useless in CI, over SSH, and in
headless agent runs. That is most of the addressable use.

Therefore:

- **`YardGit` is a standalone library.** All read commands and all non-interactive mutations run
  entirely in-process in the CLI. No app, no XPC, no launch agent.
- **The XPC connection is optional enrichment.** It is required only by the interactive commands
  (`review`, `ask`, `resolve --interactive`) and by `watch`.
- **Degradation is explicit.** An interactive command with no app running fails with exit code 3
  and a message naming what is missing. It does not silently fall back to a non-interactive path,
  because an agent would then proceed without the human approval it was told to obtain.
- Add `yard --require-app` to fail fast, and `yard <cmd> --no-launch` matching RemoteControl's
  existing flag, for callers that must not spawn a GUI app.

### XPC transport

Port the RemoteControl pattern directly. It is validated and its documentation was written for
exactly this. See `RemoteControl/docs/README.md` and `FINDINGS.md` in that repo.

Summary of the shape, so it is not relearned: a plain double-clicked app cannot publish a named
Mach service, because `NSXPCListener(machServiceName:)` only works when launchd owns the name.
So a small launch agent embedded in the bundle declares the name and acts as a bootstrap broker.
The app registers its anonymous listener endpoint with the broker; `yard` connects to the broker
by Mach service name, receives the endpoint, then connects directly to the app. After that
handoff the broker is out of the data path, and restarting it does not disturb an attached
session.

Carry forward these hard-won details from RemoteControl:

- `SMAppService.status` can disagree with launchd. Drive repair from an actually-failed broker
  call, at most once per launch, rather than trusting the reported status.
- The CLI install action must sweep `~/.local/bin` for a stale link it created, and must refuse
  to install when the app is running from a build directory.
- Keep exactly one copy of the built app on disk. Multiple copies confuse launchd's registration.
- `log` is a zsh builtin. Use `/usr/bin/log stream --predicate 'subsystem == "co.sstools.Switchyard"'`.

---

## 5. The engine decision

**Milestone 0 exists to settle this before anything else is built.** Do not scaffold the app
first.

### The libgit2 position

GitUp's inability to sign commits is not a libgit2 limitation. libgit2 exposes
`git_commit_create_buffer` and <cite index="3-1">`git_commit_create_with_signature`, which takes the unsigned commit content plus a signature and the header field to store it in, attaches the signature, and writes the commit into the repository.</cite> <cite index="2-1">What libgit2 does not do is produce the signature; that part is left to the application.</cite>

So the plan is:

1. Build the commit content with `git_commit_create_buffer`.
2. Sign that buffer.
3. Write with `git_commit_create_with_signature`, header field `gpgsig` for GPG,
   `gpgsig` for SSH as well (git stores SSH signatures under the same header).

### Signing implementation

- **SSH signing**: invoke `ssh-keygen -Y sign -f <key> -n git`. Clean, no library, no agent
  protocol to implement. Read `user.signingKey` and `gpg.format` from git config.
- **GPG signing**: invoke `gpg --detach-sign --armor`. There is no way around shelling out here,
  so no library choice avoids it.
- Respect `commit.gpgsign`, `gpg.format`, `user.signingKey`, and `gpg.ssh.allowedSignersFile`.
- Verification (`yard verify`) uses `ssh-keygen -Y verify` or `gpg --verify` correspondingly.

### The hybrid boundary

Use libgit2 for the object database, DAG traversal, index, diff, blame, and merge. Shell out to
`git` for:

- Network operations: fetch, push, clone, and anything touching credential helpers.
- Hooks. libgit2 does not run them, and silently skipping a repo's hooks is a correctness bug.
- Signing, per above.
- Worktrees, sparse checkout, and partial clone, where libgit2 lags.

Every shell-out is centralized in one `GitProcess` type in `YardGit` so the boundary is visible
and testable. No `Process` invocations scattered through the codebase.

### Milestone 0 spike

Throwaway code. Answer three questions, write the answers into `docs/engine-findings.md`, then
delete the spike.

1. Can we produce an SSH-signed commit through libgit2 that `git log --show-signature` and
   GitHub both report as verified?
2. Can we load a large repository (use one with 50k+ commits) and compute lane assignments for
   the visible window fast enough for a live UI? Record actual numbers.
3. How does libgit2 get into a SwiftPM package cleanly in 2026? Evaluate: a system library target
   plus Homebrew, a vendored C target, and the current state of the Swift bindings. Note that
   SwiftGit2 and ObjectiveGit are both worth checking for staleness before depending on either.
   A Rust `gitoxide` bridge is a legitimate alternative worth a paragraph of comparison, but the
   FFI and build complexity is real. Default to libgit2 unless the spike finds a blocker.

If question 1 or 2 fails, stop and escalate. The project's premise depends on both.

---

## 6. The `yard` CLI

### Design principles

- **Every command has a `--json` mode, and agents are expected to use it.** Human-readable output
  is the courtesy; JSON is the contract.
- **Schemas are versioned.** Every JSON response includes `"schemaVersion": 1`. Agents fail on
  inconsistent output shapes far more often than on missing features.
- **Nothing is interactive unless the command name says so.** No editor spawning, no pager, no
  prompt. `GIT_EDITOR` is never invoked.
- **Exit codes are meaningful**, and carry forward RemoteControl's assignments so the two tools
  agree.
- **Every mutating command auto-checkpoints** before it runs, so `yard undo` works without the
  caller having remembered to ask for it.
- **Errors are structured too.** A failure in `--json` mode emits
  `{"schemaVersion":1,"ok":false,"error":{"code":"...","message":"...","hint":"..."}}` on stdout,
  not a bare string on stderr.
- **Command metadata is data, not `switch` statements.** Names, flags, exit codes, and response
  schemas are declared in one place, because `--help`, the JSON schema output, and the generated
  agent skill are all derived from it. Deciding this late means retrofitting every command.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Usage error |
| 2 | Broker unreachable |
| 3 | App unavailable and required for this command |
| 4 | Request failed |
| 5 | App terminated the session |
| 6 | Repository error (not a repo, detached in a way the command cannot handle, etc.) |
| 7 | Human declined or rejected (`review`, `ask`) |
| 8 | Operation blocked on unresolved conflicts |
| 9 | Signing failed |

Codes 2 through 5 match RemoteControl exactly. Do not renumber them.

### Command groups

#### Read: structured state

| Command | Purpose |
| --- | --- |
| `yard whereami` | Branch, upstream, ahead/behind, in-progress rebase/merge/cherry-pick, stash count, dirty paths, conflict count, signing config. One object. This replaces the five-call preamble every agent runs. |
| `yard graph [--limit N] [--refs ...]` | The commit DAG with topology and lane assignment. The GitUp map view as data. |
| `yard log <range>` | Commits in a range with parents, refs, signature status, and trailers. |
| `yard status` | Worktree state, per-file, with staged and unstaged distinguished at the hunk level. |
| `yard hunks [<path>]` | Unstaged and staged hunks with **stable hunk IDs**. This is what makes precise agent-driven staging possible without `git add -p`. |
| `yard conflicts` | Per-file, per-hunk conflicts with ours, base, and theirs blob IDs. |
| `yard blame <path> [--range A:B]` | Structured blame, range-limited. |
| `yard verify <rev>` | Signature verification result. |

#### Mutate: history rewriting

These are the GitUp powers, exposed non-interactively. Interactive rebase is where agents fail
today, because it wants an editor.

| Command | Purpose |
| --- | --- |
| `yard commit [-m] [--sign] [--hunk ID...]` | Commit, optionally from a specific hunk set, optionally signed. |
| `yard fixup <target>` | Squash staged changes (or `HEAD`) into `<target>` and autosquash in one step. GitUp's flagship operation. |
| `yard absorb` | Distribute staged hunks into the correct prior commits automatically, by matching each hunk against the commit that last touched those lines. The highest-leverage command for cleaning up an agent's messy branch. |
| `yard split <commit>` | Split a commit into two along a hunk boundary. |
| `yard reword <commit> -m <msg>` | Non-interactive message rewrite. |
| `yard reorder <commit> --before\|--after <ref>` | Move a commit within the branch. |
| `yard drop <commit>` | Remove a commit. |
| `yard stage --hunk <id>...` / `yard unstage --hunk <id>...` | Hunk-level staging by stable ID. |

Every one of these writes a journal entry.

#### Undo: the journal

| Command | Purpose |
| --- | --- |
| `yard checkpoint [label]` | Explicit snapshot. Returns a checkpoint ID. |
| `yard undo [--steps N]` | Reverse the last N journaled operations. |
| `yard redo [--steps N]` | Replay. |
| `yard journal` | List journaled operations with what each touched and whether it is still undoable. |
| `yard restore <checkpoint>` | Jump to a specific checkpoint. |

See [Section 7](#7-the-journal) for the design.

#### Human-in-the-loop: requires the app

| Command | Purpose |
| --- | --- |
| `yard review <range\|--staged> --wait` | Push a diff into Switchyard, block, return `{"decision":"approve"\|"reject"\|"amend", "comments":[...], "editedPatch":"..."}`. Exit 0 on approve, 7 on reject. |
| `yard ask "<question>" --options a,b,c [--timeout N]` | Surface a decision in the app UI, block on the answer. |
| `yard resolve <path> --interactive` | Open the three-way merge UI, block, return the resolution. |
| `yard watch` | Stream repository and app events to the caller. Already proven in RemoteControl. |

`review --wait` is the command that makes this project worth building. Treat it as the
centerpiece, not a nice-to-have.

#### Agent provenance

| Command | Purpose |
| --- | --- |
| `yard commit --agent <name> --model <id> --session <id>` | Record provenance trailers on the commit. |
| `yard log --agent-only` | Filter to agent-authored commits. |

Define the trailer format once and document it in `docs/provenance.md`. Suggested shape,
following the `Co-authored-by` convention so existing tooling ignores it gracefully:

```
Agent-Name: claude-code
Agent-Model: claude-opus-5
Agent-Session: 01J8X...
```

Since signing is already implemented, a signed commit carrying provenance trailers is a
meaningfully stronger claim than an unsigned one. No existing client offers this.

---

## 7. The journal

The journal is what makes Switchyard safe for unsupervised agent use. Design it properly, early.

**Model.** A journal entry captures repository state before a semantic operation, not a diff of
what changed. Following GitUp's approach: snapshot the full ref set, `HEAD`, the index, and any
worktree state the operation will disturb. Undo restores the snapshot rather than computing an
inverse operation, which is why it works for rebases and merges where an inverse is ill-defined.

**Storage.** Journal entries live under `.git/switchyard/journal/`. Snapshotted objects are real
git objects in the ODB, kept alive by refs under `refs/switchyard/journal/`, so garbage
collection does not eat them and nothing lives outside the repository. Do not invent a
side-database.

**What is snapshotted.** Refs and index are cheap. Uncommitted worktree changes are not always
cheap. Decide the policy explicitly and document it: the reasonable default is to snapshot the
worktree only for operations that would disturb it, and to record in the entry which parts were
captured so `undo` can report honestly what it can and cannot restore.

**Pruning.** Entries expire. Default to a count limit plus an age limit, both configurable.
`yard journal --prune` cleans up, and the refs go with the entries.

**Cross-tool safety.** If the repository changed outside Switchyard since a journal entry was
written, `undo` must detect that and refuse rather than clobber. Compare recorded ref states
against current ones and fail with exit 4 and a clear explanation. This will happen constantly in
practice, since an agent will be running `git` directly alongside `yard`.

**Concurrency.** Two `yard` processes in the same repo must not interleave journal writes. Use a
lock file under `.git/switchyard/` with a timeout, and fail cleanly rather than blocking forever.

---

## 8. The agent skill, and why there is no MCP server

An agent needs two things: a tool it can call, and a document telling it when and how. `yard` is the
tool. The skill is the document.

### The skill

- **It is generated, not written.** The command set, flags, exit codes, and JSON schemas come from
  the same metadata that produces `--help`. Hand-written prose restating flags drifts from the
  binary within a milestone, and a skill that lies about flags is worse than no skill.
- **What is generated is reference; what is written is judgment.** Generate the command tables and
  schemas. Hand-write the short workflow narratives — how to go from a messy branch to a clean one,
  when to checkpoint, what to do when `undo` refuses. Keep the two clearly separated in the source
  so a regeneration never clobbers the prose.
- **One source, packaged per client.** `skills/yard/SKILL.md` is canonical. A Claude Code plugin and
  an OpenCode package wrap it. Never maintain parallel copies of the content.
- **Ship it from M1 onward.** The skill is not a milestone; it is a deliverable of every milestone
  that changes the command surface. A command lands with its documentation or it does not land.
- **`yard skill` prints the canonical markdown to stdout**, so an agent with only the binary can
  read its own instructions and no install step is strictly required.

### Why no MCP server

**Decided: no MCP server.** The original argument was context bloat — an always-loaded MCP tool
surface costs tokens in every session whether or not git comes up, while a skill costs approximately
nothing until invoked.

That argument has weakened and should be stated honestly. Clients including Claude Code now defer
MCP tool schemas and load them on demand rather than pinning every tool into the system prompt, so
the per-session cost of a large server is no longer what it was.

It has not inverted, for reasons that are not about token counts:

- A shell command works in every agent, including ones with no MCP support, and in plain scripts,
  CI, and over SSH. An MCP tool works only inside an MCP client.
- An MCP server is a process with a lifecycle, a transport, and a failure mode that looks like the
  tool silently not existing. `yard` is a binary that either runs or prints an error.
- Agents already know how to run CLI tools. The skill teaches flags, not a new calling convention.

**Revisit only on evidence**, meaning a measurement showing an MCP surface is cheaper in context
than `yard --help` plus the skill for a realistic session, or a client that agents actually use
where shelling out is not available. Until then, keep the JSON contract shaped so an MCP wrapper
stays thin dispatch over the same library — but let nothing else depend on that wrapper existing.

---

## 9. Milestones

Ship in this order. Each milestone is independently useful and independently abandonable.

**M0 — Engine spike.** Settle libgit2 packaging, signing, and graph performance. Output is
`docs/engine-findings.md` and a delete of the spike code. Nothing else starts until this lands.

**M1 — `yard` read commands, standalone.** `whereami`, `graph`, `status`, `hunks`, `conflicts`,
`log`, `verify`. No app, no XPC. JSON schemas fixed and documented. This alone is useful to an
agent on day one and validates the engine.

**M2 — Journal and safe mutation.** `checkpoint`, `undo`, `redo`, `journal`, plus `commit`,
`fixup`, `stage`, `unstage`. Signing lands here. Heavy test coverage on undo across every
mutating path.

**M3 — Switchyard.app with the graph view.** SwiftUI app rendering the graph from `YardGit`.
Read-only at first. Port the RemoteControl XPC pattern in the same milestone so the app is
reachable.

**M4 — Human-in-the-loop.** `review --wait`, `ask`, `resolve --interactive`, `watch`. This is the
differentiator. Everything before it is table stakes.

**M5 — Advanced rewriting.** `absorb`, `split`, `reorder`, `drop`. These need the rebase engine
and are the highest-effort, so they come after the thing that makes the project distinctive.

**The `yard` skill ships continuously from M1**, regenerated whenever the command surface changes.
It is not a milestone of its own. See [Section 8](#8-the-agent-skill-and-why-there-is-no-mcp-server).

**Explicitly deferred:** an MCP server (decided against, see Section 8), notarization and Developer
ID, Sparkle updates, an installer, hosting provider integrations, a sandboxed variant.

### Scope warning

GitUp took years and roughly 30,000 lines to reach 1.0. Switchyard's v1 wedge is **journaled undo
plus `review --wait`**. That pair is defensible and nothing else on the Mac has it. Resist adding
a feature at any milestone on the grounds that GitUp had it.

---

## 10. Testing

- **`YardKit` package tests are the primary suite.** Anything in the app target that is worth
  testing is in the wrong place.
- **Journal tests use real repositories.** Build fixture repos in a temp directory, run each
  mutating command, undo it, and assert the repository is byte-identical to the pre-state
  (refs, index, and worktree). This is the suite that must never be allowed to go red.
- **Graph layout tests use fixture files**, the way GitUp's do. A text notation for a DAG plus
  its expected lane assignment, one file per case. Write the notation yourself; do not copy
  GitUp's fixtures, they are GPL.
- **Signing tests** generate a throwaway SSH key in a temp dir and verify round-trip through
  `ssh-keygen -Y verify`. Skip GPG tests when `gpg` is absent rather than failing.
- **UI tests will not run under CLI-driven `xcodebuild` in this environment.** RemoteControl hit
  this: the test runner times out enabling automation mode because it lacks Accessibility rights.
  Use `-only-testing:SwitchyardTests` and verify XPC behavior with a manual script, as
  RemoteControl does.
- **Build unsigned for ordinary compile checks.** `CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO`. It is faster and avoids the certificate-revocation problem that has
  been recurring on these machines.

---

## 11. Decisions and open questions

### Settled

1. **License: MIT.** `LICENSE` is in the repo. The clean-room rules in
   [Section 2](#2-licensing-constraint-read-this-first) are what make that license honest.
2. **No MCP server.** The agent surface is the CLI plus a generated skill. Rationale and the
   conditions for revisiting are in
   [Section 8](#8-the-agent-skill-and-why-there-is-no-mcp-server).

### Still open

Decide these with Brennan, do not decide them in code.

1. **Name availability.** Domain, Homebrew formula name, npm, and the App Store name have not
   been checked. `yard` as a binary name in `/usr/local/bin` should be checked against anything
   already installed. Do this before the identifiers above are baked in.
2. **Journal worktree policy.** How much uncommitted state to snapshot, and what `undo` promises
   when it did not capture everything.
3. **Rebase engine scope.** GitUp wrote its own. How much of one does M5 actually require, and
   can `absorb` and `split` be built on narrower primitives?
4. **Distribution.** Mac App Store or direct. Affects sandboxing, which affects the Mach service
   naming scheme, which is baked in early. (MIT settles whether the source is open; it does not
   settle how the app is delivered.)

---

## Reference material

- `CLAUDE.md` — working agreements for agents: licensing rules, signing safety, build commands, traps
- `README.md` — the public description of the project
- `../../RemoteControl/docs/README.md` — the XPC pattern, written to be reused in another app
- `../../RemoteControl/FINDINGS.md` — whether XPC was worth it, and why
- `../../RemoteControl/docs/cli-embedding-and-install.md` — embedding and installing the CLI binary
- `../GitUp` — concepts only, per [Section 2](#2-licensing-constraint-read-this-first)
- libgit2 commit API: https://libgit2.org/docs/reference/main/commit/index.html
