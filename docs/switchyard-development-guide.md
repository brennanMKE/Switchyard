# Switchyard

A SwiftUI Mac git client with an agent-facing CLI. Successor in spirit to GitUp, built for a
world where a coding agent is a first-class user of the repository alongside a human.

This document is the development guide. It defines scope, architecture, naming, and the CLI
surface. It is not a task list. Work is sequenced in [Milestones](#9-milestones), and broken into
tasks in `issues/`.

Its companion, [switchyard-git-internals-and-undo.md](switchyard-git-internals-and-undo.md),
defines how the journal works against git's actual on-disk state and how worktrees are supported.
**Read it before implementing anything in the journal, the ref layer, or worktrees** — this document
says what to build and why, that one says how git will make you do it.

---

## 1. What this is

Two products and a skill, one engine:

| Product | What it is |
| --- | --- |
| **Switchyard.app** | SwiftUI macOS app. Interactive commit graph, three-way merge, review UI. |
| **`switchyard`** | CLI. Structured, non-interactive git operations for humans and agents. |
| **The `switchyard` skill** | Generated markdown teaching an agent the command set, packaged per client. |

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
| CLI binary        | `switchyard` |
| Install location  | `/usr/local/bin/switchyard` (symlink into the bundle) |
| Shared package | `YardKit` |
| Broker executable | `BrokerAgent` |
| Log subsystem | `co.sstools.Switchyard` |
| State directory | `$XDG_STATE_HOME/switchyard/`, falling back to `~/.local/state/switchyard/` |
| Per-repo journal metadata | `.git/switchyard/journal.json` |
| Journal anchor refs | `refs/switchyard/journal/<entry-id>` |

`ServiceNames.swift` in `YardKit` is the single source of truth for all of the above. Nothing
else hardcodes any of these strings.

The state directory holds what is not repo-specific: the repository registry, cross-repo recent
operations, agent session records, and UI state. `~/.local/state` beats `~/Library/Application
Support` here because `switchyard` runs in shells, CI, and agent sandboxes where the Library path is
awkward or absent. The app uses the same path, which is only true while the app stays unsandboxed —
see [Section 11](#11-decisions-and-open-questions).

---

## 4. Architecture

```
Switchyard.xcodeproj
├── Switchyard/          macOS app target (SwiftUI)
│   ├── AppXPCServer, URLSchemeHandler, AgentRegistrar
│   ├── SwitchyardApp    WindowGroup(for: WindowID.self), Settings, commands
│   ├── WindowView       tab bar (SlidingTabs) + the active repo's Git View
│   ├── GitView          the three panes: Sidebar, Graph, Detail
│   └── CLIInstallActions (File menu wiring)
├── BrokerAgent/         launch agent executable, bootstrap broker only
├── YardKit/             Swift package
│   ├── YardGit          the engine: object model, DAG, index, diff, journal
│   ├── YardKit          XPC protocols, message types, ServiceNames, CLIInstaller
│   ├── switchyard       CLI executable
│   └── Tests
├── Support/             Info.plist, entitlements, agent launchd plist
├── skills/yard/         SKILL.md (generated) + hand-written workflow prose, and the
│                        per-client packaging for Claude Code and OpenCode
├── scripts/             make-release.sh, generate-skill.sh
├── docs/                this guide, the git-internals companion, and design notes —
│                        including clean-room notes on GitUp concepts
└── issues/              NNNN.md task tracker
```

### The UI hierarchy

**Window → Tabs → Git View (three panes).** Tabs are the default and only navigation model; there is
no single-window mode to also maintain.

```
┌────────────────────────────────────────────────────────┐
│ [Switchyard ●] [Batty] [RemoteControl]            [+]  │  ← SlidingTabs, one tab per repository
├────────────┬─────────────────────┬─────────────────────┤
│ Branches   │   ● main            │  diff of the        │
│  main      │   │╲                │  selected commit    │
│  feature/x │   ● ●               │                     │
│            │   │╱                │  + hunks            │
│ Worktrees  │   ●                 │  - lines            │
│  agent-a   │   │                 │                     │
│            │   ●                 │                     │
│ Stashes    │                     │                     │
└────────────┴─────────────────────┴─────────────────────┘
   Sidebar          Graph                 Detail
```

**A tab is a repository**, and its identity is `$GIT_COMMON_DIR` — not the path the user opened.
That single choice settles several behaviors at once:

- **Opening an already-open repository focuses its tab rather than duplicating it.** Resolve the
  requested path to its common dir, look for a tab, focus it if found.
- **Opening a linked worktree focuses the parent repository's tab** and selects that worktree inside
  it, because a worktree shares the common dir. Worktrees are a sidebar section, not peer tabs — one
  tab per project, and switching worktrees happens in-tab.
- **The rule is one rule.** "Same repo" and "same path" do not need separate answers, and the
  dedup logic has one input.

Resolve with `git rev-parse --git-common-dir` through `WorktreeContext`, then canonicalize
(`realpath`) so symlinked paths and `/tmp` vs `/private/tmp` do not produce two tabs for one
repository.

The three panes are **Sidebar / Graph / Detail**: refs, worktrees, and stashes on the left; the
commit graph in the middle; the selected commit's diff — later the three-way merge and review
surfaces — on the right.

**Tab chrome comes from [SlidingTabs](https://github.com/brennanMKE/SlidingTabs)**, MIT by the same
author, depended on by tag (`from: "1.0.0"`) rather than by local path, so a public clone of this
repository builds without also cloning SlidingTabs. `SlidingTabBar` is generic over `Identifiable`
and takes a chip `ViewBuilder`, so reordering and the "+" affordance come with it.

### Multiple windows

Multiple windows are supported from the start, as in Batty: `WindowGroup(for: WindowID.self)` with a
`WindowID` value type, each window holding its own set of repository tabs.

Two traps here are already documented by Batty's `BattyApp.swift`, both from Batty issue 0251, and
**Switchyard is more exposed to the second than Batty is** because it has a URL scheme *and* XPC
waking the app:

- **The phantom second window.** `WindowGroup(for:)` needs a `defaultValue` that returns a
  `WindowID` already seeded in app state. Without it, SwiftUI's first content window creates a second
  runtime, and CLI-delivered work lands in the invisible one while the visible window sits empty.
- **External events spawning stray windows.** `.handlesExternalEvents(matching: Set())` must be on
  **every** scene, not just the main one. When the content group declines a `switchyard://` open,
  SwiftUI falls back to the next scene that accepts external events — including a Help window — and
  opens *that* instead. URL opens should be handled only by the app delegate, which routes them to
  the focus-or-open rule above.

### The layering rule

**Everything shareable lives in the package.** The app target owns only: SwiftUI views, agent
embedding, `SMAppService` registration, and the presentation of results. Anything with logic
worth testing goes in `YardKit` and has unit tests. This is the BattyKit and BridgeKit principle
carried forward.

### The CLI is a companion to the app

`switchyard` ships inside the app bundle and drives Switchyard.app over XPC. **The app owns the
engine.**

- **`YardGit` and libgit2 live in the app.** The CLI does not link them and never opens a repository
  itself. It marshals arguments over XPC and prints the reply.
- **The CLI is literally a remote control.** The reference project is named for this. The app has all
  of the functionality; the CLI is the surface that drives it. **Duplicating the engine into the CLI
  would be bad design** — it is a second implementation of the same behaviour, and two
  implementations of git state eventually disagree. The human's window and the agent's command must
  see the same repository, the same journal, and the same watchers, and the only reliable way to
  guarantee that is for there to be one of each.
- **If the app is not running, the CLI launches it** and polls the broker for an endpoint. Bound the
  wait and exit 3 when it expires. This is RemoteControl's pattern; see
  `../../RemoteControl/docs/xpc-cli-architecture.md`.
- **Degradation is explicit.** A command that cannot reach the app fails with exit code 3 naming what
  is missing. It never silently falls back, because an agent told to obtain human approval must not
  proceed without it.

> **Corrected 2026-08-06.** This section previously read "the critical constraint: `switchyard` must work
> without the app", justified by CI, SSH and headless agent runs. **That requirement was never set by
> Brennan** — it was generated, recorded as settled, and then propagated into `CLAUDE.md`, the README
> and `Package.swift`, where the CLI target still declares a dependency on `YardGit`. There is no CI
> or SSH requirement. The CLI is a companion tool, exactly as in RemoteControl.

- Add `switchyard <cmd> --no-launch`, matching RemoteControl's existing flag, for callers that must
  not spawn a GUI app. There is no `--require-app` — the app is always required, so a flag asserting
  it would mean nothing.

### XPC transport

Port the RemoteControl pattern directly. It is validated and its documentation was written for
exactly this. See `RemoteControl/docs/README.md` and `FINDINGS.md` in that repo.

Summary of the shape, so it is not relearned: a plain double-clicked app cannot publish a named
Mach service, because `NSXPCListener(machServiceName:)` only works when launchd owns the name.
So a small launch agent embedded in the bundle declares the name and acts as a bootstrap broker.
The app registers its anonymous listener endpoint with the broker; `switchyard` connects to the broker
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
- Verification (`switchyard verify`) uses `ssh-keygen -Y verify` or `gpg --verify` correspondingly.

### The hybrid boundary

Use libgit2 for the object database, DAG traversal, index, diff, blame, and merge. Shell out to
`git` for:

- Network operations: fetch, push, clone, and anything touching credential helpers.
- Hooks. libgit2 does not run them, and silently skipping a repo's hooks is a correctness bug.
- Signing, per above.
- Worktrees, sparse checkout, and partial clone, where libgit2 lags.

Every shell-out is centralized in one `GitProcess` type in `YardGit` so the boundary is visible
and testable. No `Process` invocations scattered through the codebase.

**M0 answered the reftable question, and the boundary moved.** libgit2 1.9.6 — the latest release —
cannot open a `--ref-format=reftable` repository at all, and `git` plumbing with a commit-graph is
also ~5× faster than libgit2 on the graph path. So the split above is revised:

| Concern | Goes through |
| --- | --- |
| Ref enumeration, `HEAD`, reflog, DAG traversal | **`git` plumbing** — `for-each-ref`, `rev-list`, `symbolic-ref`, `update-ref` |
| Object database, diff, blame, merge | libgit2 (reftable and commit-graph do not apply) |
| Network, hooks, signing, worktrees, sparse checkout | `git`, as before |

Switchyard keeps a `commit-graph` fresh in the background, since that is what makes the plumbing
path interactive. Full numbers and method in [engine-findings.md](engine-findings.md).

**Never read `$GIT_DIR` with `FileManager`.** Not refs, not the index, not the reflog. Reftable,
index format variants, and worktrees each break naive parsing on their own. Everything resolves
through `git rev-parse --git-path` or libgit2. This rule is absolute and the companion document
opens with it.

### Milestone 0 spike

Throwaway code. Answer four questions, write the answers into `docs/engine-findings.md`, then
delete the spike.

1. Can we produce an SSH-signed commit through libgit2 that `git log --show-signature` and
   GitHub both report as verified?
2. Can we load a large repository (use one with 50k+ commits) and compute lane assignments for
   the visible window fast enough for a live UI? Record actual numbers, **with and without a
   `commit-graph` file present** — `git commit-graph write --reachable` is cheap and Switchyard can
   keep it fresh in the background, so measuring without it measures the wrong thing.
3. How does libgit2 get into a SwiftPM package cleanly in 2026? Evaluate: a system library target
   plus Homebrew, a vendored C target, and the current state of the Swift bindings. Note that
   SwiftGit2 and ObjectiveGit are both worth checking for staleness before depending on either.
   A Rust `gitoxide` bridge is a legitimate alternative worth a paragraph of comparison, but the
   FFI and build complexity is real. Default to libgit2 unless the spike finds a blocker.
4. **Does the chosen libgit2 build work against a reftable repository?** Create one with
   `git init --ref-format=reftable`, then confirm it can enumerate refs, resolve `HEAD`, and read
   the reflog. Reftable becomes the default format for new repositories in Git 3.0, and libgit2
   support landing upstream is not the same as being in a tagged release you can build on macOS.
   Zed dropped libgit2 for the git CLI in June 2026 partly over this.

If question 1 or 2 fails, stop and escalate — the project's premise depends on both. A negative
answer to question 4 does not stop the project, but it must be settled before M1 starts, because it
relocates the entire ref and graph path onto `git` plumbing and that is not a retrofit.

---

## 6. The `switchyard` CLI

### Design principles

- **Every command has a `--json` mode, and agents are expected to use it.** Human-readable output
  is the courtesy; JSON is the contract.
- **Schemas are versioned.** Every JSON response includes `"schemaVersion": 1`. Agents fail on
  inconsistent output shapes far more often than on missing features.
- **Nothing is interactive unless the command name says so.** No editor spawning, no pager, no
  prompt. `GIT_EDITOR` is never invoked.
- **Exit codes are meaningful**, and carry forward RemoteControl's assignments so the two tools
  agree.
- **Every mutating command auto-checkpoints** before it runs, so `switchyard undo` works without the
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
| `switchyard whereami` | Branch, upstream, ahead/behind, in-progress rebase/merge/cherry-pick, stash count, dirty paths, conflict count, signing config. One object. This replaces the five-call preamble every agent runs. |
| `switchyard graph [--limit N] [--refs ...]` | The commit DAG with topology and lane assignment. The GitUp map view as data. |
| `switchyard log <range>` | Commits in a range with parents, refs, signature status, and trailers. |
| `switchyard status` | Worktree state, per-file, with staged and unstaged distinguished at the hunk level. |
| `switchyard hunks [<path>]` | Unstaged and staged hunks with **stable hunk IDs**. This is what makes precise agent-driven staging possible without `git add -p`. |
| `switchyard conflicts` | Per-file, per-hunk conflicts with ours, base, and theirs blob IDs. |
| `switchyard blame <path> [--range A:B]` | Structured blame, range-limited. |
| `switchyard verify <rev>` | Signature verification result. |

`switchyard whereami` includes a `worktree` object, so an agent's first call tells it which worktree it is
in and whether a sibling worktree holds the same branch.

#### Worktrees: agent isolation

Worktrees are the natural unit of agent isolation — one agent, one worktree, one branch, one
checkout, no interference — so they are a primary object in both the app and the CLI rather than an
advanced feature in a menu. Design detail is in
[git internals §5](switchyard-git-internals-and-undo.md#5-worktrees).

| Command | Purpose |
| --- | --- |
| `switchyard wt list` | Structured superset of `git worktree list --porcelain -z`, plus dirty state, ahead/behind, in-progress operation, attached agent session, and journal depth. |
| `switchyard wt new <name>` | Create a worktree. `--branch`, `--from`, `--detach`, `--agent <id>` (locks with a machine-readable session reason), `--template <name>`, `--sparse <paths>`. |
| `switchyard wt rm <name>` | Remove, releasing the lock and the agent session. Refuses when unclean without `--force`, matching git. |
| `switchyard wt where` | Resolve the current context: worktree id, path, `$GIT_DIR`, `$GIT_COMMON_DIR`, main worktree path. |
| `switchyard wt gc` | `git worktree prune` plus reporting of prunable and abandoned-session worktrees. |
| `switchyard wt repair [<path>...]` | Wraps `git worktree repair` for the moved-directory case. |

Two things carry disproportionate weight. **`WorktreeContext`** — worktree path, `$GIT_DIR`,
`$GIT_COMMON_DIR`, worktree id — is resolved once per invocation and every path lookup goes through
it; this is why worktrees are M1 and not later, since retrofitting means auditing every call site.
**Worktree templates** are the highest-value feature here and nothing does them well: a fresh
worktree has tracked files and nothing else, so the agent's first command fails on a missing
`node_modules` or `.env` and it starts improvising. A repo-level config listing untracked paths to
copy, symlink, or regenerate on `switchyard wt new`, plus post-create commands, fixes that for the whole
team and every agent at once.

#### Mutate: history rewriting

These are the GitUp powers, exposed non-interactively. Interactive rebase is where agents fail
today, because it wants an editor.

| Command | Purpose |
| --- | --- |
| `switchyard commit [-m] [--sign] [--hunk ID...]` | Commit, optionally from a specific hunk set, optionally signed. |
| `switchyard fixup <target>` | Squash staged changes (or `HEAD`) into `<target>` and autosquash in one step. GitUp's flagship operation. |
| `switchyard absorb` | Distribute staged hunks into the correct prior commits automatically, by matching each hunk against the commit that last touched those lines. The highest-leverage command for cleaning up an agent's messy branch. |
| `switchyard split <commit>` | Split a commit into two along a hunk boundary. |
| `switchyard reword <commit> -m <msg>` | Non-interactive message rewrite. |
| `switchyard reorder <commit> --before\|--after <ref>` | Move a commit within the branch. |
| `switchyard drop <commit>` | Remove a commit. |
| `switchyard stage --hunk <id>...` / `switchyard unstage --hunk <id>...` | Hunk-level staging by stable ID. |

Every one of these writes a journal entry.

#### Undo: the journal

| Command | Purpose |
| --- | --- |
| `switchyard checkpoint [label]` | Explicit snapshot. Returns a checkpoint ID. |
| `switchyard undo [--steps N]` | Reverse the last N journaled operations. |
| `switchyard redo [--steps N]` | Replay. |
| `switchyard journal` | List journaled operations with what each touched and whether it is still undoable. |
| `switchyard restore <checkpoint>` | Jump to a specific checkpoint. |

See [Section 7](#7-the-journal) for the model and
[git internals §3](switchyard-git-internals-and-undo.md#3-journal-design) for the mechanics.

#### Hooks: observing what `switchyard` did not do

An agent runs `git` directly between two `switchyard` commands constantly. Without these, the app's view
goes stale and the journal's cross-tool guard fires with no explanation attached.

| Command | Purpose |
| --- | --- |
| `switchyard hooks install` / `switchyard hooks uninstall` | Install the observer hooks. Detects existing hooks and `core.hooksPath`, chains rather than clobbers, and is reversible. Never silent — repositories often already have hooks. |
| `switchyard hook ref-txn` | The `reference-transaction` handler. Every ref change from any tool, batched by transaction, with old and new values. |
| `switchyard hooks status --json` | What is installed, what is chained, what is missing. |

Everything degrades to polling if hooks are declined. `post-rewrite` supplies the old→new commit
mapping that nothing else provides, which is what lets the app say "these four commits became this
one" instead of showing two unrelated graphs. Details and the abort-state trap are in
[git internals §4](switchyard-git-internals-and-undo.md#4-observing-changes-made-outside-switchyard).

#### Human-in-the-loop: requires the app

| Command | Purpose |
| --- | --- |
| `switchyard review <range\|--staged> --wait` | Push a diff into Switchyard, block, return `{"decision":"approve"\|"reject"\|"amend", "comments":[...], "editedPatch":"..."}`. Exit 0 on approve, 7 on reject. |
| `switchyard ask "<question>" --options a,b,c [--timeout N]` | Surface a decision in the app UI, block on the answer. |
| `switchyard resolve <path> --interactive` | Open the three-way merge UI, block, return the resolution. |
| `switchyard watch` | Stream repository and app events to the caller. Already proven in RemoteControl. |

`review --wait` is the command that makes this project worth building. Treat it as the
centerpiece, not a nice-to-have.

#### Agent provenance

| Command | Purpose |
| --- | --- |
| `switchyard commit --agent <name> --model <id> --session <id>` | Record provenance trailers on the commit. |
| `switchyard log --agent-only` | Filter to agent-authored commits. |

Document the settled format in `docs/provenance.md`. The shape, following the `Co-authored-by`
convention so existing tooling ignores it gracefully:

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

**This section is the model. [git internals §3](switchyard-git-internals-and-undo.md#3-journal-design)
is the mechanics** — which git primitives build a snapshot, exactly what state has to be captured,
and where each piece lives. Implement from that document; this one says why.

**Model.** A journal entry captures repository state before a semantic operation, not a diff of
what changed. Following GitUp's approach: snapshot the full ref set, `HEAD`, the index, and any
worktree state the operation will disturb. Undo restores the snapshot rather than computing an
inverse operation, which is why it works for rebases and merges where an inverse is ill-defined.

**Storage, in three places, split by what the data is.** Snapshot objects are ordinary git objects
in the ODB, anchored by refs under `refs/switchyard/journal/<entry-id>` so `gc` cannot reclaim them.
Per-entry metadata lives in `.git/switchyard/journal.json`. Cross-repo state — the repository
registry, agent sessions, UI state — lives in the state directory from
[Section 3](#3-naming-and-identifiers). Do not invent a side-database for anything git can hold.

**The repository is always authoritative.** The state directory is an index and a convenience. If
it is deleted, `switchyard journal` rebuilds from `refs/switchyard/journal/*` alone with reduced metadata.
Write that rebuild path early and test it — it is what keeps the design honest about which store is
the source of truth, and it is exactly the kind of path that rots unnoticed if it is written late.

**Snapshots outlive the process.** This is the concrete advantage over GitUp, and it falls out of
using real objects rather than in-memory state: a Switchyard snapshot survives a quit, a reboot, a
clone onto another machine, and `switchyard` running with the app closed.

**What is snapshotted.** Refs and index are cheap. Uncommitted worktree changes are not always
cheap. Decide the policy explicitly and document it: the reasonable default is to snapshot the
worktree only for operations that would disturb it, and to record in the entry which parts were
captured so `undo` can report honestly what it can and cannot restore.

**Pruning.** Entries expire. Default to a count limit plus an age limit, both configurable.
`switchyard journal --prune` deletes the anchor ref and the metadata entry together; the objects become
unreachable and ordinary `gc` reclaims them. **`switchyard` never calls `git gc` itself.**

**Cross-tool safety.** If the repository changed outside Switchyard since a journal entry was
written, `undo` must detect that and refuse rather than clobber. Every entry records a `guard` map
of ref names to expected OIDs; before restoring, compare each against its current value and on
mismatch fail with exit 4 naming the ref, the expected value, and the actual one. Offer `--force`
to a human, never to a scripted caller. This will fire constantly in practice, since an agent
running `git` directly alongside `switchyard` is the normal case rather than the exception.

**Worktree awareness is part of correctness, not a refinement.** `HEAD` and the index are
per-worktree; `refs/heads/*` are shared. So restoring `HEAD` affects only the worktree the
operation happened in, while restoring a branch ref affects every worktree that has it checked
out. An entry records which worktree it came from, restore refuses to run from a different one
without `--worktree`, and `undo` warns by name when it will disturb a sibling.

**Concurrency.** Two `switchyard` processes in the same repo must not interleave journal writes. Use a
lock file under `.git/switchyard/` with a timeout, and fail cleanly rather than blocking forever.

---

## 8. The agent skill, and why there is no MCP server

An agent needs two things: a tool it can call, and a document telling it when and how. `switchyard` is the
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
- **`switchyard skill` prints the canonical markdown to stdout**, so an agent with only the binary can
  read its own instructions and no install step is strictly required.

### Why no MCP server

**Decided: no MCP server.** The original argument was context bloat — an always-loaded MCP tool
surface costs tokens in every session whether or not git comes up, while a skill costs approximately
nothing until invoked.

That argument has weakened and should be stated honestly. Clients including Claude Code now defer
MCP tool schemas and load them on demand rather than pinning every tool into the system prompt, so
the per-session cost of a large server is no longer what it was.

It has not inverted, for reasons that are not about token counts:

- A shell command works in every agent, including ones with no MCP support, and in plain scripts.
  An MCP tool works only inside an MCP client. (This bullet previously also claimed CI and SSH; that
  was part of the standalone-CLI premise corrected in §4 and does not apply — `switchyard` needs the
  app either way. The argument stands without it.)
- An MCP server is a process with a lifecycle, a transport, and a failure mode that looks like the
  tool silently not existing. `switchyard` is a binary that either runs or prints an error.
- Agents already know how to run CLI tools. The skill teaches flags, not a new calling convention.

**Revisit only on evidence**, meaning a measurement showing an MCP surface is cheaper in context
than `switchyard --help` plus the skill for a realistic session, or a client that agents actually use
where shelling out is not available. Until then, keep the JSON contract shaped so an MCP wrapper
stays thin dispatch over the same library — but let nothing else depend on that wrapper existing.

---

## 9. Milestones

Ship in this order. Each milestone is independently useful and independently abandonable.

**Every milestone below states its exit criteria as a checklist.** The **Opus 5** milestone review
reads those and *only* those — it may file issues against a stated criterion and nothing else. That bound is
what makes the review terminate: without it, "is this good enough" has no answer and a milestone never
closes. Two consecutive reviews with no findings close the milestone.

Exit criteria are deliberately **not** umbrella issues. An umbrella issue is a way to break one
feature into several implementation tasks for a small model; a milestone criterion is a property of
the whole milestone, often spanning features, and frequently satisfied by no single issue. #0115 is
the example — forty-two M1 issues passed review individually while "the commands run" went unmet.

**M0 — Engine spike.** Settle libgit2 packaging, signing, graph performance with `commit-graph`,
and **reftable compatibility**. Output is `docs/engine-findings.md` and a delete of the spike code.
Nothing else starts until this lands.

**Exit criteria:**

- [x] `docs/engine-findings.md` answers all four questions with measured evidence, not estimates.
- [x] The spike code is deleted from the tree.
- [x] A reftable repository can be read by whatever the engine actually uses.

**M1 — the read engine and worktrees.** The engine behind `whereami`, `graph`, `status`, `hunks`,
`conflicts`, `log`, `verify`, plus the `switchyard wt` group, with its JSON schemas fixed and
documented. This validates the engine and settles the response contract.

**Exit criteria, as a checklist** — the milestone review reads these and only these:

- [x] The engine function behind each of `whereami`, `graph`, `status`, `hunks`, `conflicts`, `log`,
      `verify` exists in `YardGit`, is tested, and returns a type that encodes to a
      `schemaVersion: 1` envelope. **Verified entry point by entry point** at the tenth review pass,
      2026-08-18, with each one's file and line recorded.
- [x] The engine behind each of `wt list`, `wt new`, `wt rm`, `wt where`, `wt gc`, `wt repair`
      likewise. Same verification.
- [x] Every failure mode returns a structured error carrying the exit code from §6 — not a trap, and
      not a success value with empty fields. **This was the one criterion an M1 review found violated
      rather than merely untested**: #0287 (2026-08-18) found `worktreeList`, `yardWhere` and
      `WorktreeRepair.run` each returning an empty success value when their `git` command failed, and
      #0301 then found their new tests asserting only *that* they threw and not *what the error
      carried*. Thirty-five `exitClass` declarations now resolve to §6 codes.
- [x] The response schemas are documented and versioned (#0026, and #0194 for payload shapes —
      guide §11 decision 21).
- [ ] `swift test` is green, and every engine function has tests that can fail: each has a mutation
      recorded against a named test that dies under it. **The 2026-08-17 review found this unmet for
      `gitStatus` alone** — thirteen of fourteen mutations killed a named test, both on `gitStatus`
      survived. Filed as **#0245**; M1's clean-review count restarts when it resolves. **Passes 2, 3
      and 4 each found the same shape again in a different function** — #0247 (`whereAmI`'s upstream
      block), #0259 (its four count fields), and then #0265, #0266, #0267 together. *A field only ever
      asserted at its zero value, in a fixture that cannot produce anything else* is what this criterion
      is for, and #0259's fix immediately exposed a real production bug (#0262), which is the argument
      for keeping the hunt going rather than declaring the criterion met.

      **Fourteen passes. The tenth was clean; passes 11-14 were not, so the clean-review count is
      back to 0** — and the four passes after the clean one are the argument for not having stopped
      there. Between them they produced #0312, #0316, #0318, #0319, #0321, #0323-#0326, and then
      #0328-#0330 while the last pass's findings were being written up. Two were **data-loss or
      correctness bugs, not test gaps**: `wt rm` destroying untracked files without `--force` under
      `status.showUntrackedFiles=no` (#0319), and `hunks` emitting a patch `git apply` refuses under
      `diff.suppressBlankEmpty` (#0323).

      **The passes changed method, and that is what made them productive.** Pass 14 was asked to audit
      pass 13's enumeration rather than repeat it, and falsified its central claim — see §11's
      *Still open*, which records both the correction and the reason a class-2 enumeration bounded by
      our own source can never close. **#0330 is the fix**: it makes the property a test, so the
      criterion stops depending on a reviewer's memory.

      What the hunt was worth, since a count of findings does not say it: `status` would have **thrown**
      on any dirty repository if one flag were dropped (#0280), `hunks` would have reported *"nothing
      changed"* under `color.ui = always` (#0293) and thrown on any non-ASCII filename (#0283), `wt new`
      and `wt list` would have described the same worktree differently while silently claiming a branch
      (#0296), and `whereami` would have counted every ignored file as untracked (#0288). None was
      hypothetical; each was measured against the engine before it was filed.

**Reachability from the CLI is M3's criterion, not M1's** — decided 2026-08-07, §11 decision 11. The
two are separated because guide §5 has the CLI marshal over XPC and never link `YardGit`, and the XPC
layer does not exist until M3. Requiring "runs from the built binary" in M1 asked for something M1's
own architecture forbids. #0115 and #0124 moved to M3 with it.

The earlier phrasing — *"'Built' is not 'engine function exists'"* — was written after forty-two M1
issues resolved with nothing shippable, and the instinct behind it stands: an engine nobody can call
is not a product. What was wrong was assigning the fix to the wrong milestone. M1 now claims only what
it can deliver, and M3 owns the claim that the commands run.

Worktrees are in M1 deliberately. `WorktreeContext` has to exist before any path resolution is
written; adding it later means auditing every call site that touched a git path, which is the
definition of a retrofit nobody finishes.

**M2 — Journal, hooks, and safe mutation.** `checkpoint`, `undo`, `redo`, `journal`, plus `commit`,
`fixup`, `stage`, `unstage`. Signing lands here. **The hook layer lands here too** —
`switchyard hooks install`, the `reference-transaction` handler, and the `post-rewrite` mapping — because
the journal is not trustworthy without it: an agent running `git` directly is the normal case, and a
guard that fires without being able to say what moved the ref is a dead end for whoever hits it.
Heavy test coverage on undo across every mutating path.

**Exit criteria:**

- [ ] `checkpoint`, `undo`, `redo`, `journal`, `restore`, `commit`, `fixup`, `stage`, `unstage` each
      exist as a tested engine entry point emitting a `schemaVersion: 1` envelope. **Running them
      from the built binary is M3's criterion**, moved there 2026-08-17 (§11 decision 17) the same way
      M1's was under decision 11, and for the same reason: the CLI reaches the engine over XPC, and
      XPC is built in M3.
- [ ] `switchyard hooks install` installs the `reference-transaction` and `post-rewrite` handlers,
      chains any hook already present, and `hooks status` reports what is installed.
- [ ] The hook returns 0 immediately in **every state that is not `committed`**, and skips the
      journal's own transactions via the environment marker. (The states git 2.50.1 emits are
      `prepared`, `committed`, `aborted` — measured 2026-08-07. An earlier phrasing of this criterion
      named a `preparing` state, which git does not emit; a criterion no run can satisfy cannot close
      a milestone. Phrased as "not `committed`" so a future git that adds a state cannot break a
      repository.)
- [ ] Undo round-trips every mutating command, including with an unmerged index, and the round-trip
      suite (#0035) covers each path.
- [ ] The journal survives a rebuild from refs alone (#0030), and pruning never orphans an anchor.
- [ ] Commits sign under both SSH and GPG, and a signature that cannot be produced fails with exit 9
      rather than committing unsigned.
- [ ] `swift test` is green and every command has a test that exercises its **engine entry point**.
      Exercising the **binary** is M3's criterion (§11 decision 17).

**M3 — Switchyard.app: window, tabs, and the graph view.** The full shell — multiple windows,
repository tabs on SlidingTabs, and the three-pane Git View — rendering the graph from `YardGit`.
Read-only at first. Port the RemoteControl XPC pattern in the same milestone so the app is
reachable.

The shell is not a later polish pass. Tab identity keyed on `$GIT_COMMON_DIR` is what makes
"open this repo" idempotent, and the window model is what the XPC and URL entry points deliver
into — building either of those before the shell means routing work into a structure that does not
exist yet.

**Exit criteria:**

- [ ] The app **launches, opens a repository, and renders its graph**. Launching is the test, not
      building — #0123 crashed in dyld with both suites green.
- [ ] Every view lives in `YardUI`; `Switchyard/` holds only the `@main` `App` type, assets,
      `Info.plist`, entitlements and `SMAppService` registration (§11 decision 10).
- [ ] Multiple windows, and repository tabs whose identity is `$GIT_COMMON_DIR`, so opening the same
      repository twice focuses rather than duplicates.
- [ ] The `switchyard` binary is embedded in the bundle and drives the app over XPC; the broker
      launches the app when it is not running and the CLI exits 3 when that times out.
- [ ] **Every M1 read command runs from the built binary** — `whereami`, `graph`, `status`, `hunks`,
      `conflicts`, `log`, `verify`, and the whole `wt` group — emitting a `schemaVersion: 1` envelope
      on stdout, with `--help` listing each and `schema` emitting one for each. This criterion moved
      here from M1 on 2026-08-07 (§11 decision 11), because the CLI reaches the engine over XPC and
      XPC is built in this milestone.
- [ ] **Every M2 mutating command runs from the built binary** — `checkpoint`, `undo`, `redo`,
      `journal`, `restore`, `commit`, `fixup`, `stage`, `unstage` — emitting a `schemaVersion: 1`
      envelope. Moved here from M2 on 2026-08-17 (§11 decision 17), for the same reason as the line
      above: M2's engine work cannot be gated on a transport built in M3.
- [ ] Every command has a test that exercises the **binary**, not only the engine function.
- [ ] Every command's failure mode returns a structured error and the exit code from §6, not a trap
      and not a success envelope with empty fields.
- [ ] `SMAppService` registration succeeds, and repair is driven from a failed broker call rather
      than from reported status.
- [ ] A launch smoke test runs unattended under CLI `xcodebuild` (#0125) — no UI-automation test in
      the unattended suite.
- [ ] `swift test` is green and the app builds unsigned.

**M4 — Human-in-the-loop.** `review --wait`, `ask`, `resolve --interactive`, `watch`. This is the
differentiator. Everything before it is table stakes.

**Exit criteria:**

- [ ] `review --wait`, `ask`, `resolve --interactive` and `watch` each run from the built binary.
- [ ] Each **fails with exit 3 when the app is not running** rather than falling back to something
      non-interactive. An agent told to get human approval must not proceed without it (§8).
- [ ] A human decision is recorded as a git note and survives a fetch.
- [ ] `swift test` is green; the interactive paths have a manual verification script, since they
      cannot run unattended.

**M5 — Advanced rewriting.** `absorb`, `split`, `reorder`, `drop`. These need the rebase engine
and are the highest-effort, so they come after the thing that makes the project distinctive.

**Exit criteria:**

- [ ] `absorb`, `split`, `reorder`, `drop` and `reword` each run from the built binary.
- [ ] Every one of them is undoable through the M2 journal, proven by a round-trip test.
- [ ] `rewrite-diff` reports what changed using `range-diff`, and `post-rewrite` records the old→new
      mapping for each.
- [ ] `swift test` is green and every command has a test that exercises the binary.

**The `switchyard` skill ships continuously from M1**, regenerated whenever the command surface changes.
It is not a milestone of its own. See [Section 8](#8-the-agent-skill-and-why-there-is-no-mcp-server).

**Candidates for M5+, not committed.**
[git internals §6](switchyard-git-internals-and-undo.md#6-further-features-these-docs-surface)
develops these; two are worth naming here because they are unusually cheap relative to their value.
`switchyard rewrite-diff` uses `git range-diff` plus the `post-rewrite` mapping to answer "what changed in
the changes" after a rewrite — it is what makes the journal feel trustworthy rather than merely
present, since a reviewer who can see the delta accepts a rewrite instead of undoing it
defensively. And `rerere` means a human resolves a conflict once in the three-way UI and every
subsequent rebase replays it, which pairs directly with `resolve --interactive`.

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
- **Undo fixtures cover the states that actually break it**, not just a clean tree: an unmerged
  index (which `git write-tree` refuses, so the index file is snapshotted as a blob instead), a
  mid-rebase sequencer state, a detached `HEAD`, and untracked files.
- **Every repository fixture is built twice**, once with the default ref format and once with
  `git init --ref-format=reftable`, and the suite runs against both. Reftable becomes the default
  in Git 3.0; discovering the engine cannot read it should happen in CI, not on a user's repo.
- **Worktree tests use a real linked worktree**, not a simulated one. Assert the shared-versus-
  per-worktree ref split directly: restoring `HEAD` must not move a sibling, restoring
  `refs/heads/*` must be detected as affecting one.
- **The state-directory rebuild path is tested by deleting it.** Blow away
  `~/.local/state/switchyard/` and assert `switchyard journal` still reconstructs from
  `refs/switchyard/journal/*`. An untested fallback is a fallback that does not work.
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
3. **Journal capture policy: capture everything except ignored files, always.** Recorded in
   [journal-capture-policy.md](journal-capture-policy.md). Under-capturing loses the user's work
   silently; over-capturing costs objects `gc` reclaims. Excluding ignored files is what keeps
   "always" affordable.
4. **The CLI binary is `switchyard`, not `yard`.** Decided 2026-08-06. `yard` is taken by the Ruby
   YARD documentation tool, which declares `yard`, `yardoc` and `yri` as executables, has over 230
   million RubyGems downloads, and installs into `/usr/local/bin` — the exact path
   [Section 3](#3-naming-and-identifiers) specifies for ours. The collision is invisible until a user
   who has the gem installs Switchyard, at which point one shadows the other depending on `PATH`
   order. Findings in [name-availability.md](name-availability.md). The library targets `YardKit` and
   `YardGit` keep their names — they are module names, not commands, and collide with nothing.
5. **Distribution: direct, unsandboxed, Developer ID signed and notarized.** Decided 2026-08-06. Not
   the Mac App Store. A sandboxed build cannot install a CLI to `/usr/local/bin`, cannot publish a
   Mach service an external process can reach, and runs hooks outside its container's grants — which
   removes the entire agent-facing half of the product. Reasoning in
   [distribution.md](distribution.md). This settles that `machServiceName` keeps its unprefixed form
   and that `stateDirectory()` is genuinely shared between app and CLI.
6. **stdout is JSON on every command except `--help` and `--version`.** Decided 2026-08-06. Those two
   exist for humans and print plain text; everything an agent actually calls emits a JSON envelope
   unconditionally, with no `--json` flag needed. This keeps one output path for every real command —
   no class of bug where a command's human and JSON renderings disagree — while `switchyard --help`
   stays readable in a terminal. A `--json` flag on `--help` may later return the structured spec;
   nothing depends on it yet.

7. **`switchyard status` does not report copies.** `git status` has no copy detection — verified,
   `--porcelain=v2 -C` fails with ``unknown switch `C` ``, and the only similarity option it accepts
   is `-M` / `--find-renames`. Copy detection lives on `git diff -C`. If copies are ever wanted they
   come from a diff-based command; the status parser must not carry a `copy` state nothing can
   produce.

8. **`switchyard wt gc` reports by default; pruning is opt-in behind `--prune`.** `git worktree prune`
   cannot distinguish a *moved* worktree from a *deleted* one — both appear as
   `prunable gitdir file points to non-existent location`, naming the old path. Reaping a moved one is
   **not recoverable**: the directory stays on disk full of the user's work, and
   `git worktree repair <newpath>` then exits 1 with *"unable to locate repository"*, where before the
   prune it would have succeeded. A destructive default with `--dry-run` available inverts the risk;
   this way round, the irreversible action needs a word typed.

9. **Agent worktree locks use the reason prefix `switchyard-agent:`.** Git's own `worktree lock
   --reason` is the mechanism — no parallel registry. An entry that is `locked` with that prefix and
   whose directory no longer exists is an **abandoned session**: git never reports it as `prunable`
   and never reaps it, so nothing cleans it up but us, and we report it rather than remove it. A lock
   reason without the prefix belongs to the user and is reported as an ordinary lock.

10. **All SwiftUI views live in a `YardUI` package target, not in the Xcode project.** Decided
    2026-08-07 by Brennan. `YardUI` depends on `YardKit` and `YardGit`; the arrows point one way and
    nothing in the engine imports it.

    **The Xcode project keeps only what cannot live in a package**: the `@main` `App` type, the
    asset catalog, `Info.plist`, entitlements, `SMAppService` registration, and the embedded
    `switchyard` binary. Everything else — every `View`, every view model, every piece of formatting
    or state — is package code.

    The reason is testability. A view in the app target can only be exercised by a UI test, and UI
    tests **cannot run under CLI-driven `xcodebuild` on this machine** — the runner times out
    enabling automation mode without Accessibility rights. The same view in a package target is
    reachable from `swift test`, which runs unattended in seconds. This is the difference between UI
    logic that is covered and UI logic that is not.

    `YardUI` must set `.defaultIsolation(MainActor.self)` in its `swiftSettings`. The app target has
    `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; a package target does **not** inherit it, and views
    moved across the boundary would silently change isolation. Verified available in this toolchain
    (swift-tools-version 6.3).

11. **CLI reachability is an M3 criterion, not an M1 one.** Decided 2026-08-07 by Brennan. M1's
    checklist required every read command to *run from the built binary*; §5 requires the CLI to
    marshal over XPC and never link `YardGit`; and the XPC layer is built in M3. M1 was therefore
    asking for something its own architecture forbade, and #0115 and #0124 sat blocked on the
    contradiction rather than on any missing work.

    **M1 now claims the engine and its tests. M3 owns the claim that the commands run.** #0115 and
    #0124 move to M3 with the criterion.

    Two readings were rejected. *Link the engine into the CLI now and swap to XPC in M3* buys working
    commands in M1 at the price of rewriting roughly a dozen call sites later. *Link the engine
    permanently for read commands, keeping XPC only for the interactive ones* is cheaper than it
    sounds today — `YardGit` currently has no dependencies at all and libgit2 is not in the package —
    but it splits the engine across two processes as a standing architectural commitment, and the
    thing that made it tempting is a temporary property of the code rather than a design intent.

    The instinct behind the original criterion was right and is preserved: an engine nobody can call
    is not a product, and forty-two M1 issues resolved with nothing shippable is what taught that. The
    error was assigning the fix to a milestone that could not carry it.

12. **Observed foreign ref transactions live in their own ref namespace, `refs/switchyard/observed/`,
    not in the journal's.** Decided 2026-08-17 **in Brennan's absence, under the standing instruction
    to work the milestones through** — reversible, and flagged for his confirmation. #0153 recorded
    the fork rather than picking; two independent passes then picked the same side.

    The constraint is that `undo` must never offer an observed entry, while #0155 decision 2 fixes an
    entry's kind by the presence of `traversal` and forbids deciding it from the `operation` string.
    A separate namespace makes the safety property **structural**: observed entries cannot reach the
    chain because they are not in the space `JournalChain` reads. The alternative — an `observed:`
    field on the entry metadata — enforces the same property by agreement across four `chainNode`
    call sites, changes a wire format pinned by golden-bytes tests, and needs a new `ChainPosition`
    case so observed entries do not list as defective. #0157 had just shown how a filter that must be
    applied everywhere gets missed.

    **The cost was #0190 and is now decided there, 2026-08-17: a rebuild does not read them, and
    should not.** `JournalRebuild` reconstructs the undo/redo chain from `JournalAnchor.refPrefix`, and
    observed entries are by design not on that chain; they are also not lost, since they keep their own
    refs and `JournalObserved.list` reads them directly. The risk worth guarding turned out to be the
    opposite of the one this paragraph originally named: if rebuild's scan were ever widened to all of
    `refs/switchyard/`, every observed entry would surface as a `Defect` and a healthy repository would
    report itself partial, once per foreign transaction. #0190 pins that with a test.

    `RefSnapshot` already filters the whole `refs/switchyard/` namespace, so capture and restore are
    unaffected either way.

13. **Per-repository layout constants live in `YardGit`; `ServiceNames` keeps app, CLI and XPC
    identifiers.** Decided 2026-08-17 during #0149's planning pass, as an ordinary layering choice —
    recorded here because #0149 asked for it to be, and because the same tension recurs for every
    file switchyard puts inside a repository.

    `YardGit` must not import `YardKit` (the #0141 shape), so a per-repository path constant in
    `ServiceNames` is unreachable from the code that uses it. The code had already resolved this by
    duplication: `JournalLock` builds `commonDir + "/switchyard/" + …` from a literal, and
    `JournalMetadataCache`'s comment admits it holds *"a copy of
    `ServiceNames.journalMetadataRelativePath`"*. Two unpinned copies is the status quo the
    alternative preserves.

    So `RepositoryLayout` in `YardGit` owns where things sit **inside a repository**, `ServiceNames`
    owns the bundle identifier, Mach service name, agent plist, URL scheme and log subsystem, and a
    test in `Tests/YardWireTests` — the one target that imports both — pins them against each other so
    a rename on either side fails loudly. Migrating the two existing literals is **#0199**.

    **And never resolve one of these paths through `git rev-parse --git-path`.** Measured: for a
    subpath git does not know, `--git-path` answers *per-worktree*, so a linked worktree would resolve
    `switchyard/repository-id` under `$GIT_DIR/worktrees/<name>/` and two worktrees would disagree
    about the repository's identity. Address them from `WorktreeContext.commonDir`.

14. **A restore clears a sequencer the target never captured.** Decided 2026-08-17 in Brennan's absence
    under the standing instruction — reversible, flagged, and taken on measurement rather than taste
    (#0205). Leaving it was not a neutral default: a repository whose refs and worktree have been
    restored under a live rebase **advertises a resumable operation, refuses to resume it**
    (`cannot lock ref … is at X but expected Y`), and its one clean exit, `git rebase --abort`,
    **silently reverts the restore**. All three measured.

    Clearing makes the repository match the snapshot, which is what restore promises, and nothing is
    lost: the pre-restore entry captures the live sequencer (#0200), so the mid-rebase state is
    recoverable by restoring that entry. The journal's own guarantee is what makes a deletion on the
    restore path acceptable here, and it is the reason this is not a precedent for deleting anything the
    journal does not hold.

15. **The XPC wire between the CLI and the app carries argv in and a rendered envelope out.** Decided
    2026-08-17 in Brennan's absence under the standing instruction; it is implied by §5's own wording,
    *"the CLI marshals arguments over XPC and prints the reply"*, and it is reversible — the protocol
    is one `@objc` method with no persisted format behind it.

    ```swift
    func perform(arguments: [String],
                 workingDirectory: String,
                 reply: @escaping @Sendable (Data, Int32) -> Void)
    ```

    `Data` is the JSON envelope **exactly as the CLI must print it**, and `Int32` is the exit code. The
    CLI writes the bytes to stdout and exits; it parses nothing, so it needs no knowledge of any
    command's result shape.

    The alternative — a typed request/response per command — would make every new command a change to
    both sides of an `@objc` protocol, and would need the thirteen payload schemas of **#0194** settled
    before the first command could be wired. This shape needs none of them: the envelope already carries
    `schemaVersion` and is already pinned by `YardWireTests`, so the transport inherits a versioned
    contract instead of inventing a second one.

    Two consequences. **`workingDirectory` is explicit and never inferred** — the app's own working
    directory is meaningless to a CLI invoked in a repository, and passing it is what lets one running
    app serve CLIs in many repositories at once. And **engine-backed command arms cannot live in
    `YardKit`**, which the CLI links: they go in a `YardCommands` target that depends on `YardGit` and is
    linked by the app alone. `LayeringTests` keeps asserting that `YardKit` does not import `YardGit`
    — the assertion #0124 round 3 inverted, which is what made that round a rejection rather than a
    design.

    **Routing has three cases, not two** — added 2026-08-17 after #0124 round 2 shipped a two-way
    split. A command is *local* (`--help`, `--version`, `schema`, `noop`), *known and remote*, or
    **unknown**. An unknown subcommand is a **usage error answered locally, exit 1** (§6), and it must
    never reach the transport: with a registered broker, sending a typo to the app **launches
    Switchyard.app for a misspelling**, and with no app it reports `app_unavailable` (3) for a command
    that does not exist. `CommandRegistry.all` is the list that decides "known"; derive all three cases
    from one place.

    This decision does not cover the `reference-transaction` hook arm, which has a latency budget and
    must work with the app closed. That is **#0217**, and it is Brennan's.

17. **M2's "runs from the built binary" criteria move to M3, exactly as M1's did.** Decided
    2026-08-17 in Brennan's absence; it is bookkeeping that follows from decision 11 rather than a new
    judgement, and it is trivially reversible — two checklist lines.

    Decision 11 (2026-08-07) settled the principle: *"M1 claims the engine and its tests; M3 owns the
    claim that the commands run."* M2's checklist was written before that and still carried both
    halves, which makes **M2 unclosable until M3 finishes** — a milestone gated on a later one. The
    same two lines move, and M3's checklist gains the M2 commands beside the M1 ones it already
    lists.

    What stays in M2 is everything the journal actually is: the hook layer, undo round-tripping every
    mutating path, rebuild and pruning, and signing failing with exit 9 rather than committing
    unsigned. None of that needs a CLI.

16. **A restore detaches rather than adopting a branch a live sibling holds.** Decided 2026-08-17 in
    Brennan's absence under the standing instruction, on the same terms as decision 14 — reversible,
    flagged here, and taken on measurement. **#0211** is the finding and states the case for overruling
    it; if the strict reading of #0044 decision 2's three verbs is the one Brennan wants, this becomes a
    recorded scope clarification instead and #0211 closes `wontfix`.

    Measured, git 2.50.1: `git checkout <branch>` refuses with `fatal: '<branch>' is already used by
    worktree at …` (exit 128), but the plumbing `symref-update HEAD refs/heads/<branch>` that restore
    uses **succeeds silently**, after which `git worktree list` shows the branch claimed **twice** and
    the next commit in either worktree moves it under the other. Restore therefore manufactures a state
    git itself refuses to create.

    Adopting is not the only way to honour the snapshot. **`HEAD` at the recorded oid, detached**, puts
    the worktree on exactly the commit the snapshot recorded; only the symref is given up, and only when
    someone else is standing on it. So:

    - The branch's holder must be a **live** sibling — a `prunable` worktree record holds nothing, and
      adopting its branch is the dead-agent recovery case #0175 exists for. Key on liveness, never on
      the `allowDifferentWorktree` override; the collision predates it and happens same-worktree too
      (both measured in #0211).
    - Refusing was the alternative and is worse here: it would break the recovery path #0175 was built
      for, and a refusal at restore time is not more informative than a detached `HEAD` the caller can
      see in `whereami`.

    **#0034 decision 5** — "`HEAD` applies to the calling worktree — documented, not hidden" — was
    settled without this collision in view. It is unchanged in substance; this is the exception it did
    not consider.


18. **`GitProcess` gets an opt-in wall-clock timeout, used only at signing-adjacent call sites.**
    Decided 2026-08-17 in Brennan's absence, on the same terms as decisions 14–17: reversible, flagged
    here, and taken on measurement. **#0163** states the three options and is where the measurements
    live; option 3 (a blanket default) it rules out itself, since a clone or a fetch legitimately runs
    for minutes.

    Between the remaining two, option 1 (do nothing) leaves a real hang: `GIT_TERMINAL_PROMPT=0`,
    `GIT_ASKPASS=""` and `GIT_EDITOR=false` stop **git** prompting, and govern a **signing helper's**
    own UI not at all — gpg launches pinentry, a GUI dialog, for a passphrase-protected key, and
    `ssh-keygen` can read `/dev/tty` directly. `GitProcess.launch` calls `waitUntilExit()` with no
    bound, so that dialog blocks the engine and then whatever agent called it, indefinitely. An agent
    surface whose stated rule is *"nothing is interactive unless the command name says so"* should not
    have one.

    Option 2 is additive: a `timeout:` parameter defaulting to nil, passed only where signing is in
    effect, classified as `ExitClass.signingFailed` (9) when it fires. Nothing else changes, and
    removing it later is a parameter deletion.

    The termination semantics were measured in #0163 and decide the implementation: `terminate()`
    alone is **not** sufficient — a child that ignores `SIGTERM`, which is the shape of the case this
    is about, survives it and needs `SIGKILL` after a grace period. And a killed child reports
    `terminationStatus` **9**, which is also `ExitClass.signingFailed`'s raw value, so a timeout must
    be classified by *how the process ended* (`terminationReason == .uncaughtSignal`) and never by the
    number.

19. **An interrupted operation's entry id is persisted in `$GIT_DIR`, not carried only in the
    environment.** Decided 2026-08-17 in Brennan's absence on decisions 14–18's terms: reversible (a
    file and its writer), and taken on a measurement — **#0237**'s probe, in which a `fixup` that stops
    on a conflict stores no rewrite mapping anywhere.

    #0221 exports the in-flight entry id through `SWITCHYARD_JOURNAL_ENTRY` on the scoped
    `GitProcess` that `JournalCheckpoint.around` hands its body. That works exactly as long as the
    operation completes inside `around`. `Fixup.run` deliberately does not: it leaves a conflicted
    rebase **in progress** so the caller can resolve and continue, and the scoped process — the only
    carrier of the id — stops existing at the throw. Whatever runs `git rebase --continue` is an own
    invocation with **no id**, which both halves of the rewrite persistence refuse.

    The environment cannot span that boundary, because the boundary is a process the engine did not
    start. So the id goes on disk, in the per-worktree git directory, resolved through
    `git rev-parse --git-path` like every other path in this codebase — never concatenated onto
    `.git/`.

    The two alternatives were rejected on the same measurement. **Falling back to the newest entry for
    this worktree** is wrong the moment anything else has checkpointed since, which in the two-agent
    repository this milestone is built for is ordinary rather than exotic. **Recording it as an
    observed entry** keeps the mapping but severs it from the entry that captured the pre-operation
    state, which is the one thing bullet 5 of #0160 needs it for.

    The file is written when `around` mints the entry and removed when the operation completes inside
    it; an operation that throws mid-flight leaves it, which is exactly the case it exists for. Whoever
    consumes it removes it. **A stale file must degrade to today's behaviour** — no attach, nothing
    invented — rather than attaching a mapping to an unrelated entry.

    **Amended 2026-08-17, after #0160's third umbrella review found the first version defective.** As
    originally written this decision said the file names an *entry*, and #0237 implemented exactly
    that: a single unkeyed slot, validated only against the entry still being live — which it almost
    always is, since entries persist until pruned. Measured consequences: an abandoned operation's file
    is consumed by a **later, unrelated** rewrite, and `Fixup`'s own failure arms run `git rebase
    --abort` and then throw through `around`, so `switchyard` produces that state itself.

    **The file must name an operation that is still in progress**, not merely an entry that still
    exists. It is written only when the body leaves resumable git state, and it is validated against
    the live sequencer — `SequencerSnapshot`, or the `rebase-merge` path — before it is trusted.
    **#0241** carries the fix. The reason the file exists at all is unchanged.

20. **A restore deletes only refs its snapshot recorded.** **Brennan's decision, 2026-08-17**, on
    **#0231** — option A of three. Measured: a restore currently deletes every direct ref absent from
    the snapshot, so a branch or tag a sibling worktree **created** since the checkpoint is removed
    silently, with no refusal and nothing in the `Report`.

    What is given up is real and worth naming: `RefSnapshot.restore`'s own type comment promises the
    repository will match the snapshot, and after this it matches it **except** for refs created since.
    That is the trade Brennan took, and the reason is that the alternatives are worse — refusing needs
    a force path that does not exist until M3, and recording it as designed leaves a silent deletion.

    **It also resolves #0232**, the two-agent undo deadlock, and nothing else does. With deletion scoped
    to recorded refs, "the refs a restore touches" stops being *every ref in the repository*, so the
    cross-tool guard can be scoped to that set without weakening it — a sibling's ordinary commit no
    longer refuses the caller's traversal from step two onward.

21. **M1 criterion 4 is met by building real payload schemas, not by narrowing it.** **Brennan's
    decision, 2026-08-17**, on **#0194** — option (a), against the milestone review's own
    recommendation of (b).

    `CommandSpec` gains a payload-shape field, the thirteen shapes are expressed in it, the generated
    files carry real field lists, and the `YardWireTests` literals are bound to the generated files so
    the two cannot drift. The concrete case that made this decidable: `whereami` is now in the registry
    and its generated schema documents a success payload of `{"schema": "whereami"}` — fifteen fields,
    none named — and twelve more commands would each generate one of those.

    `Schemas/README.md`'s payload promises stand as written; it is the emitter that has to catch up.

22. **The `reference-transaction` hook arm goes over XPC like every other command.** **Brennan's
    decision, 2026-08-17**, on **#0217** — option C of three, and the one that keeps the layering rule
    without an exception: `switchyard` never links `YardGit`, and there is no second binary.

    It is taken with its consequence stated, because the consequence is not small: the arm connects
    with **`launchIfNeeded: false`** and a short timeout, so **ref transactions made while the app is
    closed are not journalled**. Journal completeness becomes a function of whether Switchyard.app
    happens to be running. A background `git fetch` in a terminal must never launch a GUI application,
    which is what `launchIfNeeded: false` buys.

    Two things follow and belong in **#0154**: the arm still exits **0** in every case (#0042's
    totality invariant — a journal that cannot record must never break a commit), and the timeout must
    be short enough that an unreachable app costs a ref update nothing measurable.

23. **A restore leaves a live sibling's held branch alone and reports it, rather than refusing the
    whole operation.** Decided 2026-08-17 in Brennan's absence, on decisions 14–20's terms — reversible,
    flagged here, and taken on a measurement. **#0251** is the finding and states the case for
    overruling it.

    Measured (#0044's fourth umbrella review): agent A checkpoints and works; agent B makes **one
    ordinary commit** in its own worktree on its own branch; A's undo is refused. And because every
    checkpoint captures every ref, **A's entire history before that commit becomes unreachable** — a
    fresh checkpoint buys exactly one step and truncates the redo tail.

    The refusal is individually correct: restoring really would move a branch out from under B. What
    was missing is any decision about restoring **partially**. Decision 2 says refuse the whole
    operation; **decision 20 has already established the opposite instinct for refs** — touch only what
    you recorded, leave the rest alone — and #0211 established the shape for reporting what was given
    up, via `Report.detachedFrom`.

    So: restore everything else, leave a **live** sibling's held branch at its current value, and name
    every branch left alone in the `Report`. Keyed on liveness exactly as #0211 is — a prunable holder
    holds nothing.

    **What this spends, stated plainly:** a restore no longer means "the repository matches this
    snapshot". An agent that undoes and then reads its own refs may find one it did not expect, and the
    only thing standing between that and confusion is the `Report` naming it. That is a real cost, and
    it is the reason B (keep refusing, add a force path) is the defensible alternative — but B needs a
    flag surface that does not exist until M3, and until then the deadlock stands in the milestone
    whose stated premise is two agents in two worktrees.

    **#0256 widens this**: a sibling stopped mid-rebase is one more holder. It applies uniformly.

24. **The in-flight entry id lives *inside* the sequencer directory, not beside it.** Decided
    2026-08-18, after #0160's sixth umbrella review found the **fifth** wrong-entry attach against the
    same root cause.

    The record of "which journal entry is this interrupted operation's" was kept in
    `$GIT_DIR/switchyard/in-flight-entry-id`, a file switchyard owns and must therefore decide when to
    delete. Four rounds tried four different rules for that — is any sequencer live (#0253), does the
    slot name a live entry (#0254), was one live when this call started (#0261), does the operation's
    `orig-head` match (#0264) — and **every one was a proxy for operation identity that turned out not
    to be unique.** `orig-head` is the last proxy git already writes, and it is provably non-unique:
    `git rebase --abort` restores `HEAD` to exactly that commit, so a retry from the same tip carries
    the identical stamp. #0264's own test only passes because it manufactures an extra commit to force
    the two apart, and its comment says so.

    **So stop guessing the lifetime and take git's.** The entry id is written to
    `rebase-merge/switchyard-entry-id` (or `rebase-apply/…`), resolved through
    `WorktreeContext.path(for:)`. **git deletes that directory on both finish and abort — measured,
    git 2.50.1, including with our file present** — so the record cannot outlive the operation it
    describes, and no staleness rule is needed at all. Also measured: an unknown file in that
    directory does not disturb `git rebase --continue`, which completes normally.

    **What this spends, stated plainly:** switchyard writes a file into a directory git owns. That is
    a coupling to git's on-disk layout of exactly the kind `CLAUDE.md` warns about — with the
    difference that it is a *write* of a file git ignores, resolved through `rev-parse --git-path`
    rather than by concatenation, and its failure mode is a missed attach rather than a corrupted
    repository. The alternative considered and rejected was dropping the mechanism entirely until
    #0217's hook glue can carry the id in its environment; that is cleaner but gives up
    already-working behaviour for a milestone.

    **One qualification, found by #0160's seventh review and worth stating rather than discovering
    twice:** the claim "the record cannot outlive its operation" is true of *git's* teardown, not of
    switchyard's own. The file now sits inside the region `SequencerSnapshot` captures —
    `buildTree` hashes every file in the directory — so a checkpoint taken while an operation is
    interrupted captures the entry-id file too, and `restore` re-materializes it. **That does not
    produce a wrong entry**: the file and the sequencer are captured and restored as one tree, so they
    stay consistent with each other, and `stillLive` catches the case where the entry it names has since
    been pruned. It is the one route by which the file can reappear, and it is the reason `stillLive`
    was kept rather than deleted with the rest of the staleness machinery.

25. **`gitStatus` keeps `-c status.renames=true` and does not add copy detection.** Decided
    2026-08-18 — reading 1, keep `status.renames=true`. **#0334.**

    **Decided by me, not by Brennan, because he asked to wrap M1 ASAP and this was the only thing in
    it blocked on a person.** It is one line and reversible; if he wants copies, #0334 reopens.

    **Why reading 1.** It is git's own default, so it changes nothing for anyone today; it keeps the
    payload config-blind, which is what #0329 was for; and copy detection is the expensive `-C` pass
    git leaves off by default, so pinning `copies` would slow every `status` call on a large
    repository to surface something almost nothing consumes. Reading 3 — a `detectCopies:` parameter
    — stays available the moment a caller actually wants it, and costs nothing to add later.

    **What this issue still owes**, and it is small: `WorktreeStatusEntry.State.copied`'s doc comment
    must say that **no production path can currently emit it**, that `gitStatus` pins
    `status.renames=true`, and that `EnumVocabularyCoverageTests`' hand-built `C.` record is what
    keeps its parsing tested. Without that note the next reader goes looking for the code path that
    produces it.

26. **`commitDiff` returns a merge commit's combined diff (`--cc`), and `HunkParser` stores combined
    hunks verbatim.** Decided 2026-08-18 — **#0342.** `git diff-tree --root -p --no-commit-id` prints
    nothing for a merge (measured #0341): `diff-tree` picks no parent without `-m`/`-c`/`--cc`, so the
    detail pane showed a merge as an empty pane, indistinguishable from "changed nothing". `--cc` —
    the combined diff, what `git show` prints for a merge by default — is the choice, and `commitDiff`
    passes it for **every** revision so the argument vector does not fork on parent count: measured
    byte-identical output for ordinary and root commits. For merges it shows exactly what the merge
    contributed relative to *all* parents: empty when the merge introduced no changes of its own
    (honest — not the parentless-refusal emptiness #0341 pinned), and otherwise only the files that
    differ from every parent — a merge-added file, or a hand-resolved conflict's `@@@` hunks.
    `--first-parent -m` was rejected for silently hiding one side's changes — untruthful in a
    bug-report context; plain `-m` was rejected because it yields one diff per parent and needs a
    parent-picker UI that does not exist.

    The parser side is policy, not interpretation: a `@@@` header line and a combined body line's
    two-character prefix (one column per parent — `--`, `- `, ` -`, `++`) are stored **verbatim**, and
    the per-column semantic reading is the pane's job. The budget rule that bounds a combined body
    (needed so a body can never swallow the next header) was derived from measured output and is exact
    on every measured shape: a line carrying `-` in column k consumes only parent k's budget; a line
    with no `-` consumes the result budget once plus each parent whose column is a space. Measured
    shapes: a dirty two-parent merge with and without surrounding context, a two-region merge (two
    `@@@` hunks in one block), the unmerged-path block `git diff` prints during a conflict, and a
    merge-added file (`@@@ -1,0 -1,0 +1,1 @@@` over `++merge`).

    **The policy necessarily widened `listHunks` too**, because the same `diff --cc` shape reaches it:
    `git diff` prints unmerged paths as combined blocks during a conflict, and those were silently
    dropped before. They now appear in the listing as their own `FileDiff` with stable ids. Staging a
    conflicted file's hunk id is still refused — `git apply` does not accept combined patches
    (measured: exit 128, "No valid patches in input"), so the all-or-none refusal keeps conflicted
    content out of the index — but the failure is now git's own refusal at the apply step rather than
    `StagingError.unknownHunkIDs`, and `Staging.swift`'s doc comment was updated to say so. If the
    reviewer wants the old typed refusal back, the place is `selectPatch`, not the parser.

    `--full-index` was re-measured for combined blocks specifically: `core.abbrev=4` shortens a
    `diff --cc` block's `index` line to `a238,0bf9..fe05` without it, and with it the line is full
    40-hex regardless of `core.abbrev` — the existing pin covers the new output shape unchanged.

### Still open

**Is M1's criterion 5 closable as written, and should it be restated?** Raised by the twelfth M1
milestone review, 2026-08-18, after twelve passes and thirty-nine findings. **This is Brennan's call; it
is recorded rather than acted on.**

**The reviewer's finding, which I think is right:** the criterion *as literally written* — "every engine
function has tests that can fail: each has a mutation recorded against a named test that dies under it"
— **was met around pass 1 and has been re-met every pass since.** Every function named in criteria 1 and
2 has a named killer on record. What twelve passes have actually been testing is an unwritten and
stronger criterion — *no reachable behaviour is unasserted* — whose search space is git's output
vocabulary × git's configuration surface × every branch and ordering in the parsers. Pass 10 was clean;
pass 11 found four; pass 12 found seven. **A clean pass has meant "this reviewer looked elsewhere", not
"the seam is exhausted."**

**The residue is not shapeless, which is the way out.** Every finding since pass 2 lands in one of five
classes: (1) a vocabulary element git can emit that no fixture produces; (2) a config-pinning flag whose
opposing config no fixture sets; (3) a scan direction where both directions agree on every fixture; (4) a
field asserted only at its zero value; (5) a hand-written conformance silently omitting a member.

**A bounded restatement**, which a review could exhaustively discharge rather than sample — for each
engine function named in criteria 1 and 2: **(a)** every case of every enum parsed out of git output
appears in a table-driven test fed the real git bytes, with the case count asserted; **(b)** every flag
or `-c` that pins git's output against user config has one test setting the opposing config, with the row
count asserted; **(c)** every hand-written `==`, `encode(to:)` and `description` is checked against its
type's stored members; **(d)** every scan whose direction is load-bearing has an input with at least two
candidates; **(e)** no field is asserted only at its zero value.

(a), (b) and (c) are derived **from the source**, so two reviewers get the same answer — and (a) and (c)
can be enforced *inside the suite*, which is **#0316**. That issue is worth doing whichever way this
question goes.

**The counter-argument, and it is real:** sampling has paid. #0262, #0280, #0283, #0288, #0293, #0296,
#0310, #0311, #0313 and #0314 are genuine defects, several of them outright failures on ordinary
repositories. What the enumeration gives up is the class *"git does something nobody has seen"* — and
that is not a property any milestone can be **shown** to have. It belongs in a standing practice (add a
fixture whenever a real repository surprises the engine) rather than in an exit criterion.

**Until this is answered, M1 stays open and the clean-review count stays at 0.** The milestone must not
close on a pass that only means one reviewer ran out of ideas.

**Evidence from the thirteenth pass, 2026-08-18 — the classes were enumerated rather than sampled, and
the numbers answer the question.** With classes 1 and 5 now enforced in-suite by #0316, that pass hunted
the other three exhaustively:

| class | enumerated | probed | already pinned | gaps |
|---|---|---|---|---|
| **2 — config-pinning flags** | 14 sites | 12 against real git | 9 | **3** (#0318, #0319, #0320) |
| **3 — load-bearing scan direction** | 21 expressions, 12 judged load-bearing | 5 mutated | 4 | **1** (#0321) |
| **4 — field asserted only at its zero value** | **60 public result fields across 13 types** | 12 | 12 | **0** |

**Class 4 is empty** — the class #0245, #0247 and #0259 were about, checked field by field rather than
sampled, with nothing left. **Class 2 is one issue from exhausted**, and its three gaps clustered in
exactly two commands. **And all four findings fell in the classes that are not enforced by
construction — none in 1 or 5 — which is direct evidence #0316 is holding.**

**So four of the five clauses can be discharged exhaustively today.** (a) and (c) by the suite; (b) by
enumerating argument vectors, which one reviewer did completely in a single pass; (e) likewise. **(d) is
the one that resists mechanisation** — "load-bearing" is a judgment about whether an input with two
candidates is constructible, not a property of the text — **but its site list is mechanical**, so a
reviewer discharging it audits twenty-one named lines rather than searching an unbounded space.

**What the enumeration still gives up**, and what belongs in standing practice rather than a criterion:
*git does something nobody has seen*, and — #0321's shape — *our own helper is only ever called with
degenerate input*. Neither is a property a milestone can be shown to have.

**Correction from the fourteenth pass, 2026-08-18 — class 2 was not closed, and how it failed is the
important part.** Pass 14 was asked to audit pass 13's enumeration rather than repeat it. **Class 4 held**
under independent sampling. **Class 2 did not**: pass 14 found three more config levers in three of
criterion 1's seven named functions — `diff.suppressBlankEmpty` (#0323, `hunks` silently drops a hunk and
emits a patch `git apply` refuses), `log.showSignature` (#0324, #0325 — a validly signed commit reported
unverifiable, and `oid` becoming an English sentence) and `i18n.logOutputEncoding` (#0326, mojibake in a
UTF-8 envelope). **None appears in pass 13's immunity list**, so they were never enumerated rather than
probed and dismissed.

**The diagnosis, which changes the restatement:** pass 13 enumerated *the places the engine already
passes a pinning flag* and asked whether each was needed — a space **bounded by what previous authors
thought of**. The space clause (b) actually needs is *for each git command the engine runs, which configs
does that command honour* — **bounded by git's documentation**. `git log` alone honours
`log.showSignature`, `i18n.logOutputEncoding`, `log.excludeDecoration`, `log.date`, `log.follow`,
`format.pretty` and `notes.displayRef`; one had been looked at. Sampling the sites pass 13 did not list
hit three in about a dozen. **So class 2's honest state is *unknown*, not *closed*.**

**And clause (e) needs one word changed.** #0327 — `shortOid`'s truncation direction, asserted by length
only — survived thirteen passes because `shortOid` is a **computed** member, and an enumeration over
*stored* result fields skips it by construction. **If the criterion is restated, (e) must read "every
public member", not "every field".**

**The highest-value next step if enforcement is extended**: a scan listing each `git.run` subcommand in
the engine against a curated table of the configs that subcommand honours. That converts clause (b) from
a reviewer's memory into a test — the only thing that would let it be called closed — and it is the
direct analogue of what #0316 did for clauses (a) and (c).

Decide these with Brennan, do not decide them in code.

1. **Rebase engine scope.** GitUp wrote its own. How much of one does M5 actually require, and
   can `absorb` and `split` be built on narrower primitives?
2. **Domain and App Store name.** Not checked. The App Store name no longer
   matters given the distribution decision above; the domain still does, for the docs site.
3. ~~**Does M1 criterion 4 cover payload shapes, or only the envelope frame?**~~ **Answered
   2026-08-17 — decision 21 above: build the payload schemas.** Original text kept for context. Filed as **#0194** by the
   2026-08-17 M1 milestone review. `Schemas/README.md` promises that `schemaVersion: 1` covers *"each
   command's result payload shape"* and that renaming *"any key an agent can currently read, in the
   envelope or in a payload"* is breaking — but no artifact records a single payload shape, and
   `CommandSpec` has no field that could hold one. Either the emitter grows payload shapes, or the
   criterion is narrowed and the promise corrected. **The README as it stands should not survive
   either answer.**
4. **Do the §6 field sets belong to a milestone?** §6 says `whereami` includes a `worktree` object,
   signing config and dirty paths; `WhereAmI` has none of them. §6 describes `wt list` as a superset
   carrying dirty state, ahead/behind, in-progress operation, agent session and journal depth;
   `WorktreeEntry` carries the porcelain parse plus `isMainWorktree`, and `lockReason` covers only the
   agent session. M1's criteria ask that the engine function exist and encode; M3's ask that the
   command run. **Nothing asks for those fields**, so today they are documentation of an intention.
5. **Are bare repositories supported at all?** Surfaced by the #0034 umbrella review, 2026-08-17.
   `JournalCheckpoint.checkpoint` now **fails in a bare repository**: #0171 made the
   `WorktreeSnapshot.capture` call unconditional, and it throws `noWorktree(gitDir:)` when
   `context.topLevel` is nil (`WorktreeSnapshot.swift:126-128`). Checkpointing a bare repo previously
   succeeded refs-only. **#0200 widened this to `restore` on 2026-08-17** — the restore flow now takes
   the same capture at its step 3, so `JournalRestore.restore` fails in a bare repository for the same
   reason. One answer settles both entry points. `WorktreeContext.isBare` exists and `JournalRebuild` is tested against a bare
   mirror clone, so parts of the engine clearly expect them — but nothing states whether the mutating
   half should. Either capture degrades gracefully when there is no worktree, or bare repositories are
   out of scope and say so.
6. ~~**Does `GitProcess` get a wall-clock timeout, and where?**~~ **Answered 2026-08-17 —
   decision 18, option 2, and #0163 is merged.** ~~**#0163**, still needing a pick among
   its three options.~~ The termination semantics it depends on were measured 2026-08-17 and are recorded
   in the issue, so whichever option is chosen is now cheap to author.

---

## Reference material

Paths below are relative to the **repository root**, not to this file.

- `docs/switchyard-git-internals-and-undo.md` — the companion: journal mechanics, hooks, worktrees
- `CLAUDE.md` — working agreements for agents: licensing rules, signing safety, build commands, traps
- `README.md` — the public description of the project
- `issues/` — the task breakdown for the milestones in [Section 9](#9-milestones)
- `../../RemoteControl/docs/README.md` — the XPC pattern, written to be reused in another app
- `../../RemoteControl/FINDINGS.md` — whether XPC was worth it, and why
- `../../RemoteControl/docs/cli-embedding-and-install.md` — embedding and installing the CLI binary
- `../GitUp` — concepts only, per [Section 2](#2-licensing-constraint-read-this-first)
- libgit2 commit API: https://libgit2.org/docs/reference/main/commit/index.html
