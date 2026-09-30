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
│   ├── WindowView       one repository's Git View; windows tab natively (#0417)
│   ├── GitView          the three panes: Sidebar, Graph, Detail
│   └── CLIInstallActions (File menu wiring)
├── BrokerAgent/         launch agent executable, bootstrap broker only
├── YardKit/             Swift package
│   ├── YardGit          the engine: object model, DAG, index, diff, journal
│   ├── YardKit          XPC protocols, message types, ServiceNames, CLIInstaller
│   ├── switchyard       CLI executable
│   └── Tests
├── Support/             Info.plist, entitlements, agent launchd plist
├── skills/switchyard/   SKILL.md (generated from CommandRegistry + SkillProse.swift), and the
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
│ [Switchyard ●] [Batty] [RemoteControl]            [+]  │  ← native window tabs, one per repository
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

**Tabs are native macOS window tabs** (#0417, §11 decision 28). Each repository is its own window,
and every repository window sets `tabbingMode = .preferred` with a repository-only
`tabbingIdentifier` (`RepositoryWindowTabbing`), so a second repository opens as a tab of the
current window. AppKit supplies the tab bar, "+", reordering, tearing a tab out, and Window ▸ Merge
All Windows.

### Multiple windows

Multiple windows are supported from the start, as in Batty: `WindowGroup(for: WindowID.self)` with a
`WindowID` value type, each window showing one repository and tabbing with the others (#0416, #0417).

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
- **One source, packaged per client.** `skills/switchyard/SKILL.md` is canonical. A Claude Code plugin and
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

**M8 — Engine operations behind the M7 UI, and in-app undo and conflict hand-off.** The typed
engine wrappers the M7 context-menu items call (#0360–#0363), Edit ▸ Undo/Redo over the journal,
and the path from an in-app conflict into the resolve pane. M6 and M7 are tracked in `issues/` only.

**Exit criteria:**

- [ ] #0387, #0388, #0389, #0390, #0391, #0392, #0393 and #0394 are resolved.

**M9 — A graph you can browse.** Set 2026-09-22 by Brennan after using the app on Batty
side by side with GitUp. The center pane becomes a branch map with no commit text, every local
branch is labelled and reachable, the filter acts on the graph, and a commit's diff moves out of
the detail pane into a window of its own. The reference screenshots are in `issues/0399/`.

**Exit criteria:**

- [ ] #0399 through #0409 are resolved, plus any children they are split into.
- [ ] #0410 is resolved: every local branch's tip sits on the map's top row with its name visible
      (children #0411-#0415, filed 2026-09-23 after Brennan tried M9 on Batty).
- [ ] On Batty (127 branches), every local branch can be found and focused from the graph or the
      sidebar without reading commit text.
- [ ] Each behaviour has a VM UI test (`scripts/run-ui-tests-vm.sh`), or a unit test where the
      behaviour is not interactive.

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

27. **A sidebar branch is "merged" by ancestry, else upstream-gone, else content — with "unknown" —
    and its ahead/behind baseline is the upstream when set, else the default branch, named in the
    row.** Decided 2026-09-13 on **#0373**, the decision issue #0372 was blocked on. The decision is
    Brennan's to overrule; it was written on dispatch because #0372 could not otherwise be planned,
    and it is reversible by editing this entry and #0372.

    Both measured repositories land work by squash — Batty has 1 merge commit among the 1,182
    reachable from `HEAD`, Switchyard 0 (measured, #0358; re-measured 2026-09-12, git 2.50.1) — so a
    squash-landed branch's commits are never ancestors of `main` and git's own meaning of merged (M1,
    ancestry) is false for nearly every landed branch: 4 of 122 on Batty, 11 of 309 on Switchyard.
    The measurements and candidate tables live in #0373; the decision:

    - **Merged = M6, the composite.** A branch row shows **merged** when its tip is reachable from
      the default branch (M1 — `%(ahead-behind:<default>)`'s ahead count 0); else **merged** when
      its upstream was deleted on the remote (M4 — `%(upstream:track)` prints `[gone]`, the
      delete-branch-on-merge hosting workflow's signature); else **merged** when
      `git merge-tree --write-tree <default> <branch>` yields the default branch's tree (M3 — the
      only candidate that recognises a squash landing of any size); else **not merged** when that
      merge yields a different tree; **unknown** when merge-tree reports a conflict. M1's "merged"
      answer is authoritative and its "not merged" is not — ahead > 0 against the default is exactly
      the squash false-negative the composite exists to repair, so it means "keep looking", never
      "unmerged".
    - **Ahead/behind = A3.** Against the branch's **upstream** when one is set — git's meaning, and
      what `WhereAmI` already reports for `HEAD` — else against the **default branch**, and the row
      **names which baseline it is showing**, because the two numbers mean different things: ahead
      of the upstream returns to 0 on push, while ahead of the default never returns to 0 after a
      squash landing (measured: Switchyard's `chore/work-logs` sits 2 1547 against `main`).
    - **Default branch source: `refs/remotes/origin/HEAD`'s symbolic target, falling back to the
      literal `main`.** Read with one `git symbolic-ref refs/remotes/origin/HEAD`. A per-repository
      setting is rejected until a repository is found where `origin/HEAD` is wrong; the literal
      `main` alone is rejected because it silently mislabels a repository whose default is `master`
      or `trunk`. Implementation caveat, measured: `for-each-ref` reports
      `refs/remotes/origin/HEAD` as if it were a commit, so the remotes enumeration must skip it.
    - **Cost budget: the synchronous sidebar-load read is one `for-each-ref` process carrying
      `%(upstream:track)` and `%(ahead-behind:<default>)` together, and nothing else.** One
      `--format` carries both atoms, so the combined read is bounded by the larger of #0373's two
      single-process measurements, not their sum: 30 ms on Batty (122 branches), 53 ms on
      Switchyard (309). The budget the engine read behind #0372 must meet is **≤ 100 ms wall clock
      on the largest measured corpus**, and it must not spawn one process per branch on the
      sidebar-load path. M3's content check is a **background pass that fills the merged column
      after the sidebar appears** — per-branch spawns measured at 7.7 s for 309 branches
      (Switchyard) and 2.2 s for 122 (Batty), with `git cherry` (M2) at 40 s there and therefore
      not used at all. Until the pass lands, the column shows *unknown* rather than blocking.

    **What the composite spends, stated plainly.** M4 is an inference, not a fact: an upstream
    deleted for any other reason — abandoned work, a renamed branch — shows *merged*, and nothing
    in the read distinguishes that from a delete-branch-on-merge landing. The composite takes it
    because the alternative is worse on the measured corpora: content alone answers *unknown* for
    102 of 121 Batty branches and 215 of 308 Switchyard branches (main excluded, #0373), and M4 is
    the one signal that costs nothing and resolves those in the common workflow. The conflict-driven
    *unknown* is kept rather than guessed at — "merging this branch would now need conflict
    resolution" is a fact about the repository, and hiding it behind a guessed answer is the kind
    of lie a sidebar cannot afford.

    **Fixture verification of the exact read shapes, 2026-09-13, git 2.50.1** (five-branch fixture
    under `build/0373-fixture/`: ancestry-merged, squash-landed, upstream-gone, unlanded,
    conflicting): one `for-each-ref` carrying `%(upstream:track)` and `%(ahead-behind:main)`
    answered every branch in 16.8 ms; the `[gone]` branch read `1 0` with an empty tree answer from
    ancestry and was merged only by the M4 rule; `merge-tree --write-tree main <b>` returned main's
    tree for the squash-landed branch, a different tree for the unlanded branch, and exit 1 for the
    conflicting branch; `git symbolic-ref refs/remotes/origin/HEAD` returned
    `refs/remotes/origin/main`.

    **Addendum, 2026-09-26 (#0422, 974db8fd).** When the default branch does not resolve (no
    `origin/HEAD` and no local `main`), no merged answer except upstream-gone can ever be reached,
    so *unknown* is permanent rather than pending. The row drops the word in that case and shows
    only upstream numbers, or nothing. *Unknown* still shows where it is honest: the default
    resolves and the content pass is pending, or merge-tree conflicted. The default-branch source
    is unchanged.

28. **Repository tabs are native window tabs; each repository is its own window.** Decided
    2026-09-26 on #0417 (planning pass, with #0416). SwitchyardApp's `WindowGroup` gives every
    repository a window (`WindowStore.place`, one repository per window, identity
    `$GIT_COMMON_DIR`), and `RepositoryWindowTabbing` makes those windows prefer tabbing. AppKit
    then provides the tab bar, "+", reorder, tear-out, Merge All Windows and tab cycling. The
    SlidingTabs chrome (`RepositoryTabBar`) was never mounted and is deleted with its dependency.
    The custom bar would have needed several repositories per window, and so a second
    which-repository-is-shown authority and per-tab content switching inside one `ContentView`,
    all of which native tabbing avoids. File ▸ New Tab (⌘T) replaces New Window, and the group's
    `defaultValue` hands out a fresh window id once the launch window has been shown, because
    "+" otherwise opened a second view of the launch window (measured in the VM).

29. **The branch map is a folded staircase tree, filtered by recency, with merged branches dimmed.**
    **Brennan's decision, 2026-09-26** (option B of the branch-map design exploration, umbrella
    **#0425**), replacing #0410's recency-ordered lanes. Decision 28 is reserved by #0417's plan;
    this entry takes 29. In his words: *"the branches should be visible at the top. At some point
    each branch should connect with a parent branch. That is the only way it should connect
    horizontally. We could clean this up by only showing branches with commits which are recent,
    like the last 2 weeks. A drop down list or slider could define the time period."* He never asked
    for commits to be time-aligned across lanes, and the map does not do it.

    - **Lanes form a tree.** One lane per branch tip. The root lane is the default branch (decision
      27's source: `origin/HEAD`'s target, else the literal `main`), else `HEAD`'s branch. Lanes
      claim first-parent history root first, then fewest-commits-the-root-does-not-reach first; a
      lane's fork point is the first commit on its first-parent chain someone else already claimed,
      and its **parent is the lane that owns that commit**. Each child lane sits immediately right
      of its parent's subtree, siblings ordered **nearest fork first** (ties: newer tip first), so
      no connector crosses a lane. Measured on #0426's layout: 0 crossings on the #0415 fixture,
      on this repository (2,394 rows, 357 lanes) and on `git/git` (5,000 rows).
    - **Exactly one horizontal per branch**: its connector, down its own lane to the fork row and
      across to the parent. **Merge edges are not drawn**, and commits no branch's first-parent
      chain claims (history merged in from deleted branches) are not drawn either; a merge commit
      still shows as a hollow node. Siblings forking from one commit share the connector line.
    - **Tips and labels on the top row; rows are a staircase.** Each lane's commits stack from row 0;
      a commit a child forks from is pushed one row below that child's lowest row. Vertical
      position means "above its fork point", never "when".
    - **Folding.** Runs of three or more commits in a lane with no fork point among them fold into
      one "⋯ N" row, the count on the marker, and so does a lane's tail below its last fork point.
      Runs of one or two stay unfolded. Clicking a fold expands it; expansion is per window, keyed
      by the fold's first commit, and not persisted. A sidebar click on a folded commit expands its
      fold.
    - **`origin/x` folds into `x`'s lane** as a chip when its tip is on `x`'s first-parent chain (the
      same commit, or behind). Ahead or diverged, it gets a lane of its own, a child of `x`'s. A
      remote-only branch gets its own lane.
    - **Recency filter, default two weeks, by tip commit date** (`%(committerdate)` of the lane's
      refs; a lane shows when any of its refs is inside the window). Choices: 1 day, 3 days,
      1 week, 2 weeks, 1 month, 3 months, All. The root lane and `HEAD`'s lane always show; a parent
      a shown lane needs in order to connect is drawn **greyed** as context; a branch clicked in the
      sidebar is revealed in the map even when the filter hides it. The control is a pop-up
      **at the top of the History pane**, not in the window toolbar: it filters only the map, and
      the window toolbar belongs to #0416/#0417's window and tab work. The choice persists
      app-wide (`@AppStorage`), a per-viewer convenience.
    - **The sidebar is not filtered.** It is the complete index of refs and the way to reach a
      branch the map hides (a click reveals it); filtering it too would leave no path to an old
      branch but changing the filter. High confidence; Brennan can overrule.
    - **Merged branches are dimmed, not hidden**, using decision 27's composite unchanged
      (`BranchStatus.mergedState`: ancestry, else upstream-gone, else the `merge-tree` content
      pass). The map runs the content pass only for the lanes it shows. In the last two weeks
      nearly every branch here is merged, so hiding them would leave an empty map. Remote-only
      lanes have no `BranchStatus` row and are never dimmed; *unknown* is not dimmed.

    Every default here is the demo's recommendation, adopted without objection; each is Brennan's
    to overrule by editing this entry and the matching child of #0425.

30. **Staging and committing live in the Detail pane's Changes view, shown when no commit is
    selected; every mutation is one journal entry.** Decided 2026-09-28 in the planning pass for
    umbrella **#0437**, with high confidence; Brennan can overrule any bullet by editing this entry
    and the matching child.

    - **Where.** With no commit (and no rerere resolution) selected, the Detail pane shows the
      Changes view. That is already the app's launch state: until now it showed a read-only
      `StatusRow` list there. A pinned **Uncommitted Changes** row sits above the branch map at the
      top of the History pane and clears the selection, so the view is one click from anywhere. It
      is the working tree's place in the history, which is where Git clients generally put it. A
      separate window or a sheet would cut the view off from the history it is about to change, and
      a sidebar entry would put working-tree content in the refs index.
    - **What it shows.** Two lists, **Staged Changes** and **Changes** (worktree edits and untracked
      files), each file with a badge, a per-file Stage or Unstage button, and Stage All or Unstage
      All on the section. Conflicted paths get their own section and no button: `git add` on one
      would mark a file that may still hold conflict markers as resolved, and the header's Resolve
      Conflicts… is the way through. Selecting a file shows its diff below the lists, with **Stage
      Hunk** or **Unstage Hunk** on every hunk. That is cheap because `listHunks`, `stageHunks` and
      `unstageHunks` already exist with stable ids. Below everything are a multi-line message editor
      and **Commit** (⌘↩). Commit is disabled with a reason while there are conflicts, nothing is
      staged, or the message is blank.
    - **Engine.** Whole files go through two new path primitives, not through hunk ids. An untracked
      file or a mode-only change has no hunks in `git diff`, so hunk ids cannot express "this file".
      `stagePaths` is `git --literal-pathspecs add -A -- <paths>`. `unstagePaths` is `git
      --literal-pathspecs reset -q -- <paths>`, not `restore --staged`, which fails on an unborn
      branch. `--literal-pathspecs` is required: without it, a file named `*.txt` stages every
      `.txt` file (measured). A staged rename is unstaged by passing both of its paths. The commit
      is `commitStaged`, which is `CommitCreate.run` inside one checkpoint. It shells out to `git
      commit -m`, so `pre-commit` and `commit-msg` hooks run and `commit.gpgsign` decides signing,
      the same as every other commit the engine makes (#0036, #0038).
    - **Undo.** Every stage, unstage and commit is exactly one `JournalCheckpoint.around` entry,
      with operation `stage`, `unstage` or `commit`. Edit ▸ Undo reads "Undo Stage", "Undo Unstage"
      or "Undo Commit" and restores the index, or the index and the branch. Stage All is one entry,
      not one per file. A refused commit (a hook exits non-zero) still leaves its pre-commit entry,
      whose undo is a no-op. That is `around`'s rule for every action that fails after its
      checkpoint.
    - **Errors.** A failure is presented as an alert titled "Couldn’t Stage", "Couldn’t Unstage" or
      "Couldn’t Commit". A git refusal shows git's stderr, which is where a hook's output lands
      (measured), without the argument vector, which would repeat the whole commit message. A
      signing failure adds that nothing was committed. The message draft survives a failure.
    - **Freshness.** The window refreshes in place whenever it becomes active, so edits made in an
      editor show when the user switches back. There is no file watcher yet.
    - **Out of scope, filed as questions in #0437:** amend, discarding worktree changes, line-level
      (partial-hunk) staging, a signing override, and the `PATH` a Finder-launched app gives hooks.

31. **The agent skill is rendered by a Swift function, printed by `switchyard skill`, and the
    directory holding it is also the Claude Code plugin.** Decided 2026-09-29 in the planning pass
    for #0066-#0069, with high confidence; each bullet is cheap to reverse.

    - **Path: `skills/switchyard/SKILL.md`.** #0102 renamed the binary to `switchyard`, so the
      skill directory takes the binary's name; `skills/yard/` in older text means this path.
    - **The prose lives in Swift, not in markers inside the markdown.** `renderSkill()` in
      `YardKit/Sources/YardKit/SkillRenderer.swift` builds the whole file: the hand-written
      judgment from string constants in `SkillProse.swift`, then the command reference from
      `CommandRegistry.all`, between `BEGIN GENERATED` / `END GENERATED` comments so a reader
      knows not to edit it. SKILL.md is never edited by hand. A golden test holds the committed file
      to the function byte for byte, as `SchemaGoldenTests` does for `YardKit/Schemas/`;
      `scripts/generate-skill.sh` rewrites it. Keeping the prose in markdown between markers would
      have forced a merge step and a resource file in the CLI; this way nothing can clobber the
      prose, and the binary carries the skill with no bundle lookup. A second test fails if a
      `switchyard …` example in the prose names a command or flag the registry does not have.
    - **`switchyard skill` prints markdown, not an envelope.** The skill is documentation, like
      `--help`, and an agent reads it as markdown. The global `--json` flag is stripped before any
      command sees it (#0420) and changes nothing here either. The command is answered locally: no
      app, no repository.
    - **The plugin root is `skills/switchyard/`.** It holds `SKILL.md` and
      `.claude-plugin/plugin.json`; the repository root holds `.claude-plugin/marketplace.json`
      with `"source": "./skills/switchyard"`. Claude Code loads a plugin with `SKILL.md` at its root
      and no `skills/` directory as a single skill (plugin manifest reference, checked 2026-09-29).
      Making the repository root the plugin was rejected: a local-path marketplace loads the plugin
      in place, so the plugin would be the whole checkout, `.build` included, and `claude plugin
      validate` warns about the root `CLAUDE.md`. `plugin.json` carries no `version`, so a
      git-hosted install is versioned by commit SHA and picks up every regenerated skill.
    - **OpenCode gets no package of its own.** OpenCode reads `SKILL.md` from
      `~/.config/opencode/skills/<name>/` and from Claude-compatible `.claude/skills/` paths, and the
      file's front matter already meets its rules (`name` matches the folder, description of at
      most 1024 characters). The README's install section gives the one-line install
      (`switchyard skill > …/SKILL.md`) for OpenCode and any other agent; #0069's separate package is
      folded into #0068.

32. **Fetch, Pull and Push are toolbar buttons for the current branch; Pull only fast-forwards,
    Push never forces, and nothing ever prompts.** Decided 2026-09-29 in the planning pass for
    umbrella **#0450**, with high confidence; each bullet is cheap to reverse, and #0450 carries the
    questions for Brennan.

    - **Where.** Three buttons in the window toolbar beside Open…: **Fetch**, **Pull**, **Push**.
      Each is disabled with its reason as help text: no remotes (all three); detached `HEAD`, no
      upstream, or an operation in progress (Pull); detached, no commits, an operation in progress,
      or nothing ahead of the upstream (Push). While one runs, the header's progress line reads
      "Fetching…", "Pulling…" or "Pushing…" with a **Cancel** button, and the three buttons are
      disabled. When it finishes the window refreshes in place, so the header's ahead/behind count
      and the history show the result.
    - **Engine: `RemoteSync` in `YardGit/RemoteSync.swift`, always a `git` shell-out.** libgit2
      runs no hooks and has no credential helpers. Fetch is `git fetch --all`, with no `--prune`, so
      the user's `fetch.prune` config decides. **Pull is `git fetch <upstream remote>` then `git
      merge --ff-only @{upstream}`, not `git pull`**: `pull.rebase`, `pull.ff` and
      `branch.<name>.rebase` would each change what `git pull` does, and a fast-forward is the one
      outcome that neither rewrites nor merges. A diverged branch fails with git's `fatal: Not
      possible to fast-forward, aborting.` and an alert that offers nothing, destructive or
      otherwise; merge and rebase are already in the history's context menu. **Push uses an
      explicit refspec**, `refs/heads/<branch>:<upstream ref>`, so `push.default=matching` cannot
      widen it (measured: a plain `git push` under `matching` sends every matching branch). A
      branch with no upstream is pushed to the same name on `origin`, or on the only remote, with
      `--set-upstream`. With several remotes and none named `origin` it refuses rather than guess.
      Force-push is out of scope.
    - **No prompts, ever.** `GitProcess` already sets `GIT_TERMINAL_PROMPT=0` and empties
      `GIT_ASKPASS` and `SSH_ASKPASS`. **Measured 2026-09-29 by launching a script bundle through
      Finder** on this Mac: the app's environment is `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME`,
      `USER`, `SHELL`, `TMPDIR` and **`SSH_AUTH_SOCK`**, which launchd sets for every GUI process
      (`launchctl getenv SSH_AUTH_SOCK` returns the same socket). `ssh-add -l` in that environment
      listed the agent's keys, `git config credential.helper` resolved `osxkeychain` from Xcode's
      system gitconfig, and `tty` printed `not a tty`. So SSH keys in the agent and HTTPS
      credentials in the keychain work with no environment repair, and `ssh` has no terminal to
      prompt on. A missing credential fails fast: with `GIT_TERMINAL_PROMPT=0`, `git credential
      fill` exits 128 with `fatal: could not read Username for 'https://…': terminal prompts
      disabled` (measured). The failure is an alert with git's stderr, `hint:` lines removed, plus
      one sentence saying where to add the credential. What the minimal `PATH` does break is a
      helper or hook that is not on it, such as a non-absolute `gh auth git-credential` helper or
      Git LFS's `pre-push` hook. That is #0437's question 3, and it stays open (#0450 question 1).
    - **Cancel.** Fetch and push run through `GitProcess`'s async `run`, whose task cancellation
      terminates the child (SIGTERM, then SIGKILL). Measured on a push blocked in a `pre-push` hook
      that sleeps 60 s: cancelling returns `CancellationError` and the remote is unchanged. In Pull
      **only the fetch is cancellable**. The merge runs through the synchronous `run`, which
      cancellation does not reach, because a merge killed halfway through a checkout would leave the
      worktree half-updated. A cancel presents no alert.
    - **The journal.** Fetch and Pull each write one entry, `fetch` or `pull`, **before** they run
      (`JournalCheckpoint.checkpoint`, the same rule as `around`). **Undo Fetch** puts the
      remote-tracking refs back where they were. The fetched objects stay, the next Fetch brings the
      refs forward again, and refs the fetch created are left alone (decision 20). **Undo Pull**
      puts back the branch, the worktree and the remote-tracking refs (measured: the pulled file
      leaves the worktree and `git status` is clean). The entry matters beyond Undo Fetch itself.
      Every snapshot records `refs/remotes/*`, so without a `fetch` entry the next Undo of an
      earlier operation would rewind the fetched remote-tracking refs as a side effect. Measured: commit, then an
      unjournaled `git fetch` that moves `origin/main`, then Undo Commit — the undo succeeds and
      `origin/main` is back at its pre-fetch value. With the entry, that rewind is its own step,
      named Undo Fetch. **Push writes
      its `push` entry after it succeeds, not before.** It records the state after the push, so
      restoring it changes nothing. Edit ▸ Undo shows **"Can’t Undo Push"**, disabled, whenever the
      entry Undo would restore is a push: the remote already has the commits and no local restore
      can take them back. Undo stays blocked there until a later operation is journaled, which
      makes the push a wall that Undo does not cross. A failed or cancelled push writes no entry,
      so Undo still names the operation before it.
    - **Addendum 2026-09-29 (#0461): the engine enforces the wall, for every caller.** The menu
      alone left `JournalUndo.undo` itself willing to restore the push marker (a no-op) and then
      the entry before it, rewinding `origin/<branch>` locally while the remote keeps the commits.
      That is reachable from any non-menu caller, and from the CLI's `undo [--steps N]` once it
      exists. So `JournalUndo.undo` refuses, in planning and before anything is written, whenever a
      step would restore an entry whose `operation` is `JournalUndo.pushOperation` (`"push"`):
      `JournalUndo.Error.pushNotUndoable(entry:requested:available:)`, exit class 6
      (`repositoryError`, the class every journal refusal carries), message naming the push entry.
      `undo --steps N` that would cross a push is refused whole, like one that asks for more steps
      than exist. Redo is not blocked (it only walks back toward the present), and restore-by-id
      is a different verb, not covered here. The app keeps its disabled "Can’t Undo Push" item, so
      a user never meets the error. This is the one place a decision is made by matching
      `operation`, a deliberate exception to #0034 decision 7: a push entry is a normal entry by
      every structural test. Decided by the orchestrator with high confidence; answers #0450
      question 5.
    - **Tests never touch the network.** Every engine test uses a bare repository in a temporary
      directory as the remote, and the VM fixture (`scripts/uitest-fixtures/make-remote-fixture.sh`)
      builds its bare remotes inside the guest.

33. **Amend is a toggle beside Commit in the Changes view; it never rewrites a pushed commit.**
    Decided 2026-09-29 in the planning pass for umbrella **#0462** (#0437's question 1), with high
    confidence; each bullet is cheap to reverse, and #0462 carries the questions for Brennan.

    - **Where.** An **Amend** checkbox left of **Commit** under the message editor. Turning it on
      sets the draft aside and fills the editor with `HEAD`'s full message; turning it off puts the
      draft back. While it is on the button reads **Amend** (still ⌘↩) and the caption reads
      "Amending <short oid> · N files staged". A successful amend clears the editor and turns the
      checkbox off. The checkbox is disabled, with its reason as help text, when the branch has no
      commits, when `HEAD` is already on a remote-tracking branch, or while a merge, rebase,
      cherry-pick or revert is in progress. The button is disabled while conflicted paths remain or
      the message is blank. **Nothing staged is allowed**: that is a message-only amend.
    - **Engine: `AmendHead` in `YardGit/AmendHead.swift`.** `AmendHead.target(at:)` reads `HEAD`'s
      oid, its full message (`git log -1 --no-show-signature --format=%B`) and the refusal, if any.
      `AmendHead.run` is `git commit --amend -m <message>` through `CommitCreate.run(amend: true)`,
      so hooks run and `commit.gpgsign` decides signing, as for every commit (decision 30). It is
      one `JournalCheckpoint.around(operation: "amend")` entry: Edit ▸ **Undo Amend** puts back the
      old commit and the index, with the staged changes staged again (measured). The author and
      author date stay `HEAD`'s, which is git's `--amend` rule.
    - **Pushed means any remote-tracking ref contains `HEAD`**, not only `@{upstream}`: `git
      for-each-ref --contains HEAD refs/remotes/`, symbolic refs such as `origin/HEAD` skipped. A
      branch just cut from `main` has no upstream yet but sits on `origin/main`'s commit, and
      amending that rewrites published history as surely. The refusal names the upstream when it is
      one of the containing refs, else the first. Rewriting it could only reach the remote by a
      force-push, which the app never does (decision 32). **The engine refuses too**, before the
      checkpoint, for every caller (`AmendHead.Refusal`, exit class 6), the lesson of #0461: a guard
      that lives only in a disabled control is not a guard. A stale remote-tracking ref can make a
      commit read as pushed when the remote has since dropped it; Fetch corrects that.
    - **A merge commit may be amended.** `git commit --amend` keeps both parents (measured), and the
      journal undoes it like any amend. The history's rewrites refuse merges because a replay would
      lose the second parent; an amend replays nothing.
    - **Git's own refusals are shown, not pre-empted.** During a merge git refuses with `fatal: You
      are in the middle of a merge -- cannot amend.` (measured); the checkbox is disabled then
      anyway. An amend whose result would be an empty non-root commit fails with git's "would make
      it empty" text on stderr (measured); `--allow-empty` is not passed. Both arrive as a
      "Couldn’t Amend" alert with git's stderr, the same shape as "Couldn’t Commit".

34. **Discard is per file (and per hunk) in the Changes view, confirmed by a dialog naming what it
    throws away, and Edit ▸ Undo Discard brings it back byte for byte from the journal.** Decided
    2026-09-29 in the planning pass for umbrella **#0467** (#0437's question 2), with high
    confidence; each bullet is cheap to reverse, and #0467 carries the questions for Brennan.

    - **Undo needs no new journal machinery.** #0437 deferred discard because "the journal would
      need a worktree snapshot". It already has one: every `JournalCheckpoint.checkpoint` captures
      `WorktreeSnapshot` — every tracked file's worktree bytes and mode (a copy of the index plus
      `add -u`, deleted files included as absences) and every untracked, non-ignored file — and
      every restore applies it. Measured on the planning prototype (#0468's tests): discard, then
      `JournalUndo.undo`, returns text, a binary file with NUL bytes, an executable bit, a symlink
      that had been replaced by a regular file, a deleted file, an untracked file, a file named
      `*.txt` and an untracked directory byte for byte, and `git status` is identical. So a discard
      is one `JournalCheckpoint.around(operation: "discard")`, and the Edit menu reads **Undo
      Discard**.
    - **Where.** Each row in the **Changes** list gets a **Discard Changes…** context-menu item, and
      the section header a **Discard All…** button beside Stage All. In the selected file's diff,
      each unstaged hunk gets **Discard Hunk…** beside Stage Hunk. Staged rows and staged hunks
      offer no discard.
    - **Every discard asks first.** A confirmation dialog titled "Discard changes to <file>?" or
      "Discard changes to N files?", naming the files (the first ten, then "and N more"), saying that
      untracked files are deleted when any are, and that Edit ▸ Undo Discard brings them back. The
      destructive button is **Discard**, with no Return shortcut (#0359's rule for Delete Commit).
    - **Staged changes are never touched.** A tracked file goes back to its *index* version with
      `git --literal-pathspecs restore --worktree --`, whose source is the index. A file with staged
      and unstaged edits keeps the staged ones. Throwing a staged change away is Unstage, then
      Discard. Restore works on an unborn branch (measured).
    - **Untracked files are deleted, not moved to the Trash.** `git --literal-pathspecs clean -f -q
      --` removes exactly the untracked, non-ignored files the snapshot captured. An ignored file
      inside an untracked directory stays, where a recursive delete would destroy something no
      snapshot holds (measured: `dir/a.o` survives `clean -f -- dir/`). The Trash was rejected. Undo
      would then leave a second copy in the Trash, and a trashed directory would take its ignored
      files with it. The journal is already the recovery path for every other operation.
      Pruning is manual (`journal prune`), so a discarded file stays recoverable until the user
      prunes.
    - **The engine refuses, before the checkpoint,** a conflicted path (resolve it instead), an
      intent-to-add path (`git restore` empties it: measured, `ita.txt` becomes 0 bytes), an
      untracked directory that is its own repository (`git clean -f` skips it silently at exit 0,
      and `update-index` "Ignoring path" means no snapshot holds it), a submodule, and a path with
      no unstaged change. `DiscardChanges.Refusal`, exit class 6. The UI offers no discard on
      conflicted or intent-to-add rows. The other refusals arrive as a "Couldn’t Discard" alert.
    - **A hunk** is `git apply --reverse` of the patch `stageHunks` already builds (`selectPatch`
      over the unstaged listing), with no `--cached`. It is the same atomic apply, aimed at the
      worktree.
    - **Byte for byte has one exception: content filters.** The snapshot stores the *clean* form
      (it goes through `git add`), and restore writes it back through smudge. Under
      `core.autocrlf=input` a CRLF file comes back with LF (measured). The same applies to
      `.gitattributes` `eol`/`text` and to Git LFS. With no filters, which is the default on macOS,
      it is exact. This is true of every Undo, not only Discard's. #0467 question 2.
    - **Undo Discard restores the whole worktree to the moment before the discard, like every
      Undo.** Measured: discard `a.txt`, then edit `b.txt` and create `c.txt`, then Undo. `b.txt` is back to its
      old content and `c.txt` is gone. Redo brings them back, because the undo writes its own
      pre-restore entry. This is the journal's existing contract, not something discard adds. It
      matters more here, because a discard invites editing afterwards. #0467 question 1.

35. **Lines inside a hunk are selected in the Changes view's diff and staged, unstaged or discarded
    with a patch that holds only those lines.** Decided 2026-09-29 in the planning pass for umbrella
    **#0474** (#0437's question 5, #0467's question 6), with high confidence; each bullet is cheap to
    reverse, and #0474 carries the questions for Brennan.

    - **Where.** In the selected file's diff, `+` and `-` lines are selectable: a click selects one
      line, shift-click extends from the last click, ⌘-click adds or removes a line, and a drag
      selects the changed lines it crosses. Selected lines are drawn with the accent color. A
      selection lives in one hunk; a click in another hunk starts a new one. A plain click on a
      context line, or on the only selected line, clears it. While a hunk has selected lines its
      header buttons read **Stage Lines** (**Unstage Lines** on the staged side) and **Discard
      Lines…**; with none they are Stage Hunk and Discard Hunk…, so no new control appears. The
      selection clears when another file is selected. A refresh keeps it: it names a hunk by id,
      a hash of the hunk's lines, so a changed hunk drops out of it by itself. Discard Lines… asks
      first with the same dialog as Discard Hunk… ("Discard 2 lines of t.txt?"), decision 34's rule.
    - **Engine: `YardGit/LineStaging.swift`.** `stageLines(hunkID:lines:)`,
      `unstageLines(hunkID:lines:)` and `DiscardChanges.discardLines(hunkID:lines:)` take a hunk id
      from a fresh listing and indices into its `body`. The id is a hash of the body, so a live id
      names the same lines; a stale one is refused as `StagingError.unknownHunkIDs`, and an index
      that is not a `+`/`-` line as `StagingError.notAChangedLine`. Each is one journal entry,
      operation `stage`, `unstage` or `discard`, so Undo reads as it does for a hunk.
    - **The patch.** The side `git apply` matches against is kept whole; only the other side loses
      the unselected changes. Staging (`git apply --cached`): an unselected `-` line becomes
      context, an unselected `+` line is dropped. Unstaging (`--cached --reverse`) and discarding
      (`--reverse`, worktree): the other way round. Counts are recounted; starts are kept. Two
      corrections, both measured against git 2.54.0, and both cases where git would otherwise
      damage a file with exit 0: a `\ No newline at end of file` line that the selection puts
      lines after is split into `-L` / `+L` (git otherwise joins `b` and `c` into `bc`), and a
      partial new or deleted file drops its `new file mode` / `deleted file mode` line and
      replaces `/dev/null` with the path (dropping only the mode line makes git remove the whole
      file from the index). Every non-empty selection of twelve fixture cases, in all three
      directions, was checked against `git apply` (#0476).
    - **CRLF.** `HunkParser` now splits on the newline scalar. Swift reads `"\r\n"` as one
      Character, so the old split left a CRLF file's body as one line that swallowed every file
      after it (measured on `main`; #0475).
    - **Not `git apply --recount`, and not `stagePatch`.** Computing the counts keeps the patch
      exact and testable as text; `stagePatch` applies forward only and writes its own entry.
    - **Out of scope, filed as questions in #0474:** a selection across hunks or files, keyboard
      selection, and a CLI surface for line staging.

36. **Stashes are listed in the sidebar and shown in the Detail pane; Stash Changes…, Apply, Pop
    and Drop… are each one journal entry, and the journal captures the stash list itself.**
    Decided 2026-09-29 in the planning pass for umbrella **#0489**, with high confidence; each
    bullet is cheap to reverse, and #0489 carries the questions for Brennan.

    - **The journal needs a new piece, because a stash is a reflog entry, not a ref.** `stash@{1}`
      exists only as the second line of `refs/stash`'s reflog, and `RefSnapshot` records
      `refs/stash`'s oid and nothing else. Measured on git 2.54.0: dropping `stash@{1}` leaves
      `refs/stash` unchanged, so restoring refs brings nothing back; dropping `stash@{0}` and
      writing `refs/stash` back with `update-ref` returns the oid as a new reflog line with an
      **empty message** (`stash@{0}: `); and a stash pushed onto an empty list creates
      `refs/stash`, which a restore leaves alone (decision 20), so the stash would survive its
      own Undo. So every checkpoint also captures **`StashSnapshot`**: the list as `<oid>
      <message>` lines, newest first, stored as a `stash` blob in the anchor tree, with every
      stash oid a keep-alive parent so a dropped stash stays reachable. Restore compares it with
      the live list and, when they differ, rebuilds the reflog: `update-ref -d refs/stash`
      (removes the ref and its reflog), then one `update-ref --create-reflog -m <message>
      refs/stash <oid>` per entry, oldest first. Not `git stash store`: it refuses a commit that
      is not stash-like (exit 128), and a refusal halfway through would leave the list half
      rebuilt. An empty list is an empty blob, which restore honours by deleting `refs/stash`; an
      entry written before this change has no blob and leaves the list alone. Reflog timestamps
      become the restore's; nothing shows them (the sidebar dates a stash by its commit). git
      collapses a newline or tab in a stash message to a space when it writes the reflog
      (measured), so the line format cannot be broken.
    - **The stash list is repository-wide, and so is its restore.** `refs/stash` lives in the
      common directory. Undo in one worktree puts the list back as the entry recorded it, which
      also removes a stash a sibling worktree made since; Redo brings it back. This is decision
      34's rule (Undo restores the whole snapshot) applied to the one piece every worktree
      shares. #0489 question 1.
    - **Engine: `Stash` in `YardGit/Stash.swift`, always `git stash`.** `list` (one `git stash
      list --format`, parents and committer date included), `push(message:includeUntracked:)`,
      `apply(oid:restoreIndex:)`, `pop(oid:restoreIndex:)`, `drop(oid:)`. A stash is named by its
      **oid**; the `stash@{n}` index is looked up at the moment of the call, and an oid no longer
      listed is refused rather than acting on a neighbour. Operation strings `stash`,
      `stash-apply`, `stash-pop`, `stash-drop` (not `drop`, which is Delete Commit's); Edit ▸ Undo
      reads **Undo Stash Changes**, **Undo Apply Stash**, **Undo Pop Stash**, **Undo Drop Stash**.
    - **Refusals, before the checkpoint** (`Stash.Refusal`, exit class 6): no commits (git: "You
      do not have the initial commit yet"), nothing to stash (git prints "No local changes to
      save" and exits **0**, which would leave an entry for nothing), conflicted paths (git:
      "could not write index" / "needs merge" for push and apply), an intent-to-add path (git:
      "Entry '…' not uptodate. Cannot merge."), and an oid no longer listed. All measured.
    - **Pop is `git stash pop`, one entry.** git applies, then drops only when the apply had no
      conflict. **A conflict is an outcome, not an error**: git applies what it can, leaves
      conflict markers and unmerged paths, keeps the stash ("The stash entry is kept in case you
      need it again.", exit 1) and starts no operation, so there is no Continue or Abort. The
      engine returns `.conflicted(paths:)`; the app says so in an informational alert and the
      header's existing **Resolve Conflicts…** (#0394) is the way through. Undo Pop or Undo Apply
      puts the tree and the list back as they were. Any other non-zero exit is thrown with git's
      stderr: local changes to the same file ("would be overwritten by merge", nothing changed),
      an untracked file in the way ("already exists, no checkout" — tracked changes **are**
      applied first, measured, so the alert says Undo puts things back), `--index` failing
      ("conflicts in index. Try without --index.", nothing changed).
    - **Apply and Pop bring staged changes back unstaged, as git does; a Restore staged changes
      checkbox passes `--index`.** Measured: without it a staged edit comes back unstaged and a
      staged new file stays added; with it both come back staged.
    - **Stash Changes… includes untracked files by default.** A button left of Amend in the
      Changes view opens a sheet: an optional message, **Include untracked files** (on), Stash.
      On by default because the Changes list shows untracked files and Stash Changes should empty
      it; git's own default is off. Disabled with a reason while there are conflicts or no
      changes. Works on a detached `HEAD` (git names it `(no branch)`).
    - **Where the list lives.** The sidebar's Stashes section lists every stash: its message and
      `stash@{n}` · its date. Clicking one shows it in the Detail pane like a commit: the
      message, the base commit, whether it holds untracked files, and its files' diffs (tracked
      changes against the base, then untracked files as new files), with **Apply**, **Pop** and
      **Drop…** and the Restore staged changes checkbox. The row's context menu has the same
      three. **Drop… asks first**: "Drop stash “<message>”?", saying Edit ▸ Undo Drop Stash
      brings it back, destructive button **Drop** with no Return shortcut (#0359's rule).
    - **Errors** are alerts titled "Couldn’t Stash Changes", "Couldn’t Apply Stash", "Couldn’t
      Pop Stash" or "Couldn’t Drop Stash" with git's stderr, the shape of decision 30.
    - **Out of scope, filed as questions in #0489:** `git stash branch`, stashing selected files
      or hunks (`push -- <paths>`, `--staged`, `--patch`), `--keep-index`, renaming a stash, and
      CLI verbs.

37. **The CLI gains `stage`, `unstage`, `commit`, `discard`, `fetch`, `pull`, `push`, `stash`,
    `undo` and `redo`, each a thin arm over the engine call the app's button makes.** Decided
    2026-09-29 in the planning pass for umbrella **#0497**, with high confidence; each bullet is
    cheap to reverse, and #0497 carries the questions for Brennan. Prototyped end to end in a
    planning worktree and run through `yard-engine` and the full suite.

    - **Grammar.** `stage (<path>... | --hunk <id>...)`, `unstage (<path>... | --hunk <id>...)`,
      `discard (<path>... | --hunk <id>...)` — paths or hunk ids, never both, `--hunk` repeatable,
      `--` before a path that starts with `-`. `commit [--message <message>] [--amend] [--sign |
      --no-sign]` — `--message` required except with `--amend`, which then keeps `HEAD`'s full
      message (`git commit --amend --no-edit`). `fetch`, `pull`, `push` take no arguments.
      `stash (list | push [--message <message>] [--include-untracked] | apply <stash> [--index] |
      pop <stash> [--index] | drop <stash>)` — a subcommand is required, never git's implicit
      push; `<stash>` is `stash@{n}`, a bare `n`, or a full oid, resolved to an oid once and acted
      on by oid (decision 36). `undo [--steps <n>]`, `redo [--steps <n>]`, `n` a positive integer.
      Flag names are git's (`--include-untracked`, `--index`, `--amend`), not the app's labels,
      and flag defaults are git's: `stash push` leaves untracked files unless asked, where the
      app's sheet defaults the checkbox on.
    - **Paths are repository-relative, whatever the current directory**, exactly as `status`,
      `hunks` and `conflicts` print them, and literal (`--literal-pathspecs`, #0438). Every arm
      runs git from `WorktreeContext.topLevel`. Measured: `stage a.txt` from `sub/` stages the
      top-level `a.txt`; `stage ../a.txt` is git's "outside repository", exit 6. `unstage` of a
      staged rename by its new path also unstages the old path (#0439's trap), which the app's
      `WorkingChanges` does and an agent would not know to.
    - **Routing is unchanged.** Each is a `CommandRegistry` name, so `route` classifies it
      `.remote`, the CLI hands argv to the app over XPC (decision 15), and the app answers from
      `runEngineCommand` — one new case per arm, one new file per arm in `YardCommands`. The app
      owns the engine; the CLI links nothing new. `yard-engine` gets every verb for free.
    - **Exit codes come from the error.** The older arms flatten every engine failure to 4. These
      convert an `ExitClassCarrying` error to its own §6 class — 6, 8 or 9 — and anything else to
      4, the conversion `ExitClass`'s doc comment reserved for wiring time: a hook refusing a
      commit, a stale hunk id or `nothing to redo` is 6, a signing failure is 9. One shared
      helper, `engineFailure` in `YardCommands/EngineServing.swift`.
    - **An outcome to branch on is `ok: true` at a non-zero exit**, as `review`'s reject (7) and
      `resolve`'s remaining conflicts (8) are. A `stash apply` or `pop` that conflicts exits **8**
      with `{"outcome":"conflicted","conflictedPaths":[…]}`; git applied what it could and kept the
      stash (decision 36).
    - **`discard` takes no confirmation flag.** The app asks because a click is cheap to misplace;
      an agent's argv is deliberate, `drop` and `branch delete` ask nothing either, and the call is
      one `discard` entry that `switchyard undo` restores byte for byte (decision 34, measured
      through the CLI). The engine still refuses what a snapshot cannot hold (a nested repository,
      intent-to-add, a conflicted path), and a pathspec cannot widen it: every path must name a
      `status` entry. `stash drop` likewise.
    - **Fetch, pull and push get synchronous twins in `RemoteSync`**, the reverse of `Stash.list`'s
      async twin, because `runEngineCommand` is synchronous and a semaphore bridge is the pattern
      the Swift guidance forbids. Same probes, same entries (fetch and pull before, push after),
      same refusals; `pushPlan` and `upstreamRemote` are factored out so the refspec rules live
      once. Not cancellable from the CLI — interrupting the CLI does not stop the app's git. No
      prompts: the app's environment and `GitProcess` already disable them (decision 32).
    - **Undo and redo** pass `command: "switchyard undo …"` into the traversal entry (the
      parameter `JournalUndo` kept for this), and report each step: the entry restored, the
      pieces restored and not, `detachedFrom`, `leftAlone`, and for undo the `operation` undone
      (the restored entry's metadata, as `JournalMenu.undoOperation` reads it). A walk that asks
      for more than remains or would cross a push is refused whole (#0461) — measured: after a CLI
      `push`, `undo` exits 6 and `origin/main` stays put.
    - **Payloads.** `stage`/`unstage`/`discard` echo `{"paths":[…]}` or `{"hunks":[…]}`; `commit`
      `{oid, amended}`; `fetch` `{remotes}`; `pull` `{outcome: upToDate|fastForwarded, from?, to?}`;
      `push` `{remote, remoteRef, setUpstream}`; `stash list` `{stashes:[item]}`, `stash push` the
      new `stash@{0}` item (`name`, `index`, `oid`, `baseOID`, `includesUntracked`, `date`,
      `message`), apply/pop `{oid, outcome, conflictedPaths?}`, drop `{dropped}`; undo/redo
      `{steps:[…]}`. The flat ones (`commit`, `pull`, `push`) declare a `PayloadShape`.
    - **Tests** run each arm in-process against a `FixtureRepository` (bare remotes in a temporary
      directory, never the network), plus one test that spawns the built `yard-engine` for
      stage → commit → undo. The shipping `switchyard` binary cannot be driven to the app in a test
      without launching it, which tests never do; its routing is covered by the registry.
    - **Out of scope, filed as questions in #0497:** line-level staging (`hunkID` + body indices
      are too fragile for argv), `commit --hunk`, provenance flags on `commit`, `journal`,
      `checkpoint` and `restore`, force-push, `pull --rebase`, fetching one remote, `stash branch`,
      stashing selected paths, `--keep-index`.

38. **Switching, checking out and deleting refs: the sidebar's branch, remote and tag rows, and the
    Commit menu; `git switch`'s own rule for local changes, with Stash Changes and Switch.** Decided
    2026-09-29 in the planning pass for umbrella **#0506**, with high confidence; every bullet is
    cheap to reverse, and #0506 carries the questions for Brennan. Prototyped end to end in a
    planning worktree (engine, views, VM spike).

    - **Where.** A local branch row: **double-click** switches, and its context menu has **Switch to
      “x”** and **Delete Branch…**. A remote branch row: **Check Out as Local Branch** (`origin/x` →
      a new `x` tracking it). A tag row: **Delete Tag…**. The Commit menu (and the History row's
      context menu, which is the same menu): **Check Out (Detached)**. A disabled item's help text
      says why, from the same rules the engine refuses by.
    - **Engine.** `Checkout.switchBranch` (`git switch --no-guess`), `Checkout.trackRemote`
      (`git switch --create x --track refs/remotes/origin/x`), `Checkout.detach` (`git switch
      --detach`), `Tag.delete` (`git tag -d`), and the existing `Branch.delete`. **Each is one
      journal checkpoint**, operations `switch`, `switch-track`, `switch-detach`, `tag-delete`,
      `branch-delete`, so Edit ▸ Undo reverts it; the checkpoint captures `HEAD`, the index and the
      working tree, so Undo Switch Branch puts all three back.
    - **Local changes follow `git switch` exactly.** A change to a file that is the same in both
      commits is carried across; a change the checkout would overwrite — modified, staged, or an
      untracked file in the way — refuses the whole checkout and touches nothing. There is no
      "discard and switch" and no `--merge`. The refusal is decided **before** the checkpoint with
      the same two-way merge `git switch` runs, as a dry run — `git read-tree -m -u -n HEAD
      <target>` after `git update-index -q --refresh` — so a refused switch writes no journal
      entry. Measured (git 2.54.0): the dry run refuses exactly what `git switch` refuses and
      passes what it carries; without the refresh it refuses a file whose stat data changed and
      whose content did not. The dry run names only the first file; the refusal's file list is the
      paths that differ between `HEAD` and the target *and* have a local change.
    - **The refusal is a question.** The app shows "Your changes would be overwritten by checking
      out “x”" with **Stash Changes and Switch** and **Cancel**. Stash Changes and Switch is
      `Stash.push` (untracked files included, message "Before checking out x") then the checkout —
      **two journal entries**, so the first Undo switches back and the second puts the changes
      back in the working tree. Chosen over opening the Stash Changes… sheet because the sheet
      would leave the user to click Switch again; the stash stays visible in the Stashes list.
    - **Refusals the app checks first** (and the engine refuses anyway): switching to the current
      branch; to a branch another worktree has checked out (git refuses to check one branch out
      twice); any checkout while a rebase, merge, cherry-pick or revert is in progress or the index
      has conflicts; Check Out as Local Branch when a local branch of that name exists, or on
      `origin/HEAD`; detaching where `HEAD` is already detached.
    - **Delete Branch… always asks.** The first dialog never forces: the engine decides whether the
      branch is merged (its tip reachable from `HEAD`, `git branch -d`'s rule). When it is not, the
      engine's refusal becomes a **second** dialog — "“x” is not merged into the current branch",
      destructive **Delete Unmerged Branch** — which forces. No typed confirmation: Undo Delete
      Branch restores it. The current branch and a branch another worktree holds cannot be
      deleted (disabled, with the reason). **Delete Tag…** asks once; Undo restores a lightweight
      or an annotated tag (the tag object is still in the store — switchyard never runs `git gc`).
    - **Undo of Check Out as Local Branch leaves the new branch** (and its upstream config): decision
      20, a restore deletes only refs its snapshot recorded — the same way Undo New Branch leaves
      the branch it made. `HEAD`, the index and the working tree go back. Measured.
    - **Out of scope, filed as questions in #0506:** CLI verbs (`switch`, `tag delete`), choosing
      the local name when checking out a remote branch, deleting a remote branch (a push),
      renaming a tag, and switching from the History row's branch chips.

39. **A file's history and its blame are one read-only inspector in the Detail pane, over the
    selection, opened from a file's context menu; History is `git log --follow`; clicking a commit
    in it selects that commit in the History pane beside it.** Decided 2026-09-29 in the planning
    pass for umbrella **#0513**, with high confidence; prototyped end to end in a planning worktree
    (engine, views, VM spike). #0513 carries the questions for Brennan.

    - **Where: the Detail pane, not a sheet or a window.** The feature's one cross-pane interaction
      — click a line's commit, see it in History — only works when History is on screen beside
      it. A sheet is modal and covers History; a window (the #0406 changes window's shape) would
      need cross-window routing back to its repository window and would put that window over
      the blame. The Detail pane is already "what the current selection shows" (decisions 30
      and 36), and its splitter widens it. The inspector sits **over** the selection: opening it
      does not change what is selected, its close button shows the selection again, and any
      selection the user makes (a History row, a sidebar ref or stash, the working tree row)
      closes it. A commit clicked **inside** it is selected in History and scrolled to
      (`HistoryScrollRequest`, #0401) while the inspector stays, so the user can keep reading
      the blame and close it to see that commit.
    - **Entry points.** Show History and Blame on a Changes-view file row's context menu (not
      on an untracked or a conflicted row; Blame disabled on a deleted one), on each of a
      commit's changed files in `CommitDetailView` (at that commit; Blame disabled for a file the
      commit deleted), and File ▸ Show File History… / Blame File… — an open panel in the
      worktree, for any file nothing lists. A History row's context menu has Blame This Version.
      The inspector's header switches between History and Blame for the same file.
    - **History is `git log --follow <rev> -- <path>`, always, one file.** `<rev>` is the commit
      the file was opened at, or `HEAD` for the working tree. Measured on git/git (git 2.54.0,
      `builtin/log.c`, renamed from `builtin-log.c` in 81b50f3ce4): `--follow` lists **609**
      commits — all **431** non-merge commits that touched `builtin/log.c` (none lost) plus
      **178** from before the rename — and **no merges**; without it, **636** (431 plus 205
      merges) and nothing before the rename. `-c diff.renames=false` does not change the 609.
      `--follow` refuses two paths (`fatal: --follow requires exactly one pathspec`), so a folder
      has no history view. A **staged rename** follows from its original path, which is the one
      `HEAD` has (from the new path the log is empty — measured). Merges are not listed; each
      row shows what the commit did to the file (Added, Renamed from x, Deleted).
    - **Blame is `blameFile` (#0018)**: the working tree's file, with its not-yet-committed lines
      marked, or the file at the commit. Rows are grouped into runs by commit: the gutter (short
      oid, author, abbreviated relative date) shows on a run's first line, and alternate runs
      are shaded.
    - **A commit History has not loaded opens its changes window instead.** History loads the
      newest 5,000 commits (#0405); a blame of an old file reaches far past them (on git/git,
      most of it). Selecting what is not in the list would do nothing, so the click opens that
      commit's changes window (#0406) — the one surface that shows any oid.
    - **Off the main actor, cancellable, lazy.** Both loads are `@concurrent`; blame gains an
      async twin on `GitProcess`'s non-blocking path, so switching files or modes terminates a
      running `git blame`. The blame is a `LazyVStack` in a two-axis `ScrollView` (lines do not
      wrap); the gutter strings are made off the main actor with the parse. Measured on git/git
      (debug build, host): `builtin/log.c` (2,820 lines) history 0.59–1.14 s, blame 0.29–0.35 s,
      of which the row building is 8–11 ms; `diff.c` (7,881 lines) blame 0.59–0.61 s. `git` is
      the cost.
    - **Read-only.** No journal entry, no ref written.
    - **No CLI verb in this pass.** `switchyard log` refuses every `-`-prefixed token, so
      `log -- <path>` is not reachable; `blame` has no verb. Both are thin arms over
      `FileHistory.run` and `blameFile`, left to a later issue with the grammar chosen (#0513
      question 4).

40. **History search reaches authors, changed paths and diff content: a Commits | Paths | Content
    scope in the History pane's match bar; Paths and Content ask git about the loaded commits
    only.** Decided 2026-09-29 in the planning pass for umbrella **#0521**, with high confidence;
    prototyped end to end in a planning worktree (engine, view, VM spike). #0521 carries the
    questions for Brennan.

    - **Why this gap, over the next two.** After #0402 the one filter field finds a commit by
      its message, a ref name or an oid prefix — **not by who wrote it, which files it touched,
      or what text it added or removed**, the three questions a daily user asks of history most
      ("when did this folder change", "who added this string"). GitUp's search covers them, and
      nothing in the app answers the last two at all: file history (decision 39) is one file,
      `--follow`, never a folder or a pattern. It is also the cheapest large gap: one engine
      function, one view edit, no new window, read-only. **Remote management** (add, rename,
      remove a remote; edit its URL) was the runner-up — needed once per clone, not daily, and
      the terminal does it in one line. **Whitespace and word-diff options** were third: real,
      but a refinement of a view that works, where search is a question the app cannot answer.
      Cherry-pick, revert, merge, rebase, tag and branch creation already ship on the commit
      menu (#0359); incoming and outgoing commits already show as the header's ahead/behind
      count and remote-only history's dashed lanes (#0358, #0368).
    - **Author joins the Commits scope's in-memory match** (`HistoryFilter`), case- and
      diacritic-insensitively like the message. No git call: every loaded `CommitLogEntry`
      already carries `%an`.
    - **One field, three scopes, chosen in the match bar** — the bar that appears when the field
      has text (#0402), so the choice sits beside the count it changes. Not a query syntax
      (`author:`, `path:`): nothing in the app teaches one, and a word typed as a path must not
      silently search messages. Not a union of all three: typing "filter" would light up every
      commit that touched a file named for it along with every message saying it, and the count
      would stop meaning anything. The scope is per window and resets to Commits; the sidebar
      keeps narrowing refs by the same text whatever the scope (#0378).
    - **Paths** is `git log -- ':(icase)*<text>*'`: a commit matches when it changed a file whose
      path contains the text, in a directory name or a file name — the default pathspec's `*`
      matches `/` (measured). `*`, `?`, `[`, `]` and `\` are backslash-escaped so they match
      themselves (unescaped, `*[ird]*` matched every commit of the measuring repository;
      escaped, the one touching `we[ird].txt`). **Content** is `git log -M -i -S<text>`: a
      commit matches when it changed how often the text occurs — added or removed it — case-
      insensitively. `-M` pins rename detection: with `diff.renames=false` a renaming commit
      matched every line of the renamed file (measured on #0520's fixture: "charlie" matched
      the rename as well as the commit that added it). Both use `--no-merges`: a merge's
      changes are its branches' commits, which match on their own — without it a merge whose
      parents both touched matching paths is listed too (measured).
    - **Only the loaded commits are searched**, passed on stdin to `git log --no-walk=unsorted
      --stdin`. History holds the newest 5,000 (#0405), a match can only be shown if it is
      loaded, and the bound makes the cost the window's rather than the repository's. Measured
      on git/git (85,179 commits reachable; git 2.54.0, host): over the 5,000 loaded, a path
      search takes **0.28–0.29 s** and a content search **0.41 s**; the same searches walking
      everything take **2.0 s** and **7.8 s**. An empty stdin lists nothing (not `HEAD`), and
      the engine does not run git for no candidates or a blank query anyway.
    - **Off the main actor, debounced, cancellable.** The view runs the search in a
      `.task(id:)` keyed on the text, the scope, the repository and the loaded history; each
      keystroke restarts it, a 250 ms sleep lets typing settle, and a cancelled task terminates
      its `git` (`GitProcess`'s async path). The count reads "Searching…" while git runs;
      matches dim and step (⌘G / ⇧⌘G) exactly as #0402's do.
    - **Read-only.** No journal entry, no ref written. **No CLI verb** in this pass —
      `switchyard log` refuses `-`-prefixed tokens (decision 39's last point applies unchanged).

41. **Remotes are managed from the sidebar's Remotes section: each remote is a row (name, fetch
    URL) above its remote-tracking branches, with Fetch, Prune, Edit URL…, Rename Remote…,
    Remove Remote… and Add Remote… on its menu. Add and Edit URL are not journaled; Rename and
    Remove write an entry after they succeed that Undo refuses, as a push's is.** Decided
    2026-09-30 in the planning pass for umbrella **#0526**, with high confidence; prototyped end to
    end in a planning worktree (engine, views, VM spike). #0526 carries the questions for Brennan.

    - **Where.** The Remotes section already lists remote-tracking branches; it now lists each
      configured remote (`git remote -v`, one process, URLs after `insteadOf` rewriting — what git
      contacts) as a row above its own branches, with its fetch URL on a second line and every
      push URL in the help text when they differ. Branches no configured remote owns (a ref left
      by a removed remote, a hand-made `refs/remotes/x/y`) list after the groups, as before. The
      section shows even with no remotes ("No remotes"), so **Add Remote…** — on the section
      header's menu, the "No remotes" row and every remote row — is always reachable. Remote rows
      are not selectable (they are not commits); the branch rows keep #0401's click, #0510's menu
      and their `origin/x` labels.
    - **Git decides what a name may be; the sheet says so first.** `git remote add` accepts a name
      exactly when `git check-ref-format refs/remotes/<name>/test` does (measured on 47 names, git
      2.54.0); `RemoteConfig.nameProblem` mirrors it and a test runs git on every name. Two rules
      are Switchyard's own: a leading `-` (git accepts it after `--`, and every later `git fetch
      <name>` reads it as an option) and a name that nests with an existing one (`a` beside
      `a/b`), which `git remote add` refuses but `git remote rename` does not (measured). A URL
      must be non-empty with no control characters and no leading `-`: git itself accepts an
      empty URL and one containing a newline (which splits `git remote -v`'s line — measured).
      Surrounding whitespace is trimmed.
    - **Not journaled: Add Remote… and Edit URL….** A remote is `git config`, and a journal entry
      captures refs, `HEAD`, the index, the worktree, the sequencer and the stash — never config
      (`JournalCheckpoint`). Neither moves a ref, so Edit ▸ Undo keeps naming the operation before
      it and restoring that entry leaves the new configuration alone. Each sheet says "Edit ▸ Undo
      doesn't undo this" and how to take it back.
    - **Rename and Remove write a marker entry after they succeed, and Undo refuses it** — the
      push rule (decision 32, #0461), for a different reason: both move refs *and* config, and a
      restore can only put the refs back. Measured: after `git remote remove origin`, undoing the
      entry before it recreated `refs/remotes/origin/main` for a remote that no longer existed;
      a rename would leave the old name's branches beside the new. So `JournalUndo` refuses to
      restore a `remote-rename` or `remote-remove` entry (`Error.remoteChangeNotUndoable`), and the
      Edit menu reads "Can’t Undo Rename Remote" / "Can’t Undo Remove Remote", disabled. Earlier
      entries stay reachable only by restoring them explicitly (`switchyard restore`), as after a
      push. A rename or removal that fails writes no entry.
    - **Remove Remote… always asks, and says what goes**: its remote-tracking branches are deleted
      (named, up to three, then "and N more"), and each local branch whose upstream it was stops
      tracking it — `git remote remove` unsets both `branch.<b>.remote` and `branch.<b>.merge`
      (measured); local branches and commits stay. Destructive button, no Return shortcut (#0359).
      Rename moves `refs/remotes/<old>/*` and rewrites `branch.<b>.remote` (measured), which its
      sheet says.
    - **Fetch “name” and Prune “name” are per remote and undoable.** Fetch is `git fetch --
      <name>`, journaled as `fetch` before it runs (decision 32's entry, one remote). Prune is `git
      remote prune -- <name>`: it deletes the remote-tracking branches the remote no longer has and
      fetches nothing; journaled as `prune` before it runs, so Edit ▸ Undo Prune brings them back.
      Both contact the remote, so they run as the toolbar's `remoteTask` and the progress line's
      Cancel terminates them. Add Remote…'s **Fetch its branches now** (on by default) runs Fetch
      after the add as a second step: a new remote with no branches listed looks like one that did
      not work.
    - **Edit URL… changes the fetch URL** (`remote.<name>.url`, prefilled as configured, before
      `insteadOf`); a separately set push URL is shown and left alone. Editing push URLs is not in
      this pass.
    - **No CLI verbs in this pass.** `switchyard remote add|rename|remove|set-url` would be thin
      arms over `RemoteConfig`; left to a later issue with decision 37's shape (#0526 question).

42. **Diff views get a Diff Options menu: Ignore Whitespace (`-w`), Highlight Changed Words (in
    the app, on by default) and Context (3 lines, 10 lines, whole file). Anything but the standard
    diff turns hunk and line staging and discarding off, visibly, until Reset.** Decided 2026-09-30
    in the planning pass for umbrella **#0534**, with high confidence; prototyped end to end in a
    planning worktree (engine, views, VM spike). #0534 carries the questions for Brennan.

    - **Where.** A bar over the diff in the three places a diff is read — the Changes view's
      selected file, the commit changes window (#0406) and the stash detail pane (#0496) — holding
      a **Diff Options** menu (`slider.horizontal.3`) and, when an option is on, a line saying
      which ("Whitespace ignored · Whole file"). Not the View menu in this pass: the menu items
      would need a focused-value route to whichever pane owns the diff, and the bar puts the
      choice beside the thing it changes. The review sheet, the Resolve pane and rerere's detail
      follow the word-highlight setting but have no bar.
    - **Ignore Whitespace is `--ignore-all-space` (`-w`)**, not `--ignore-space-change` (`-b`) or
      `--ignore-space-at-eol`. Measured on git/git's newest 2,000 non-merge commits: `-b` changes
      the `--shortstat` of 282, `-w` of 317 — every one `-b` changes plus code moved into a new
      block (9719c290ee: 7/8 lines plain and under `-b`, 2/3 under `-w`), since `-b` still shows a
      line indented from nothing; `--ignore-space-at-eol` changes none. The cost of `-w` — it also
      hides `a b` → `ab` inside a string — is why the bar always says it is on. **A file whose
      every change is whitespace disappears from `git diff -w` entirely** (no `diff --git` block,
      measured), so each view keeps the standard listing for its file list and draws "Only
      whitespace changed in <path>" where that file's diff would be.
    - **Word highlights are computed in the app, not by `--word-diff=porcelain`.** A run of `-`
      lines directly followed by an equally long run of `+` lines is paired line by line and
      diffed by token (words, whitespace runs, single punctuation; Swift's `difference(from:)`);
      the changed tokens get a stronger tint of the line's own color. Unequal runs, pairs sharing
      less than half their text, lines over 500 characters and combined (`@@@`) hunks get none.
      Measured on git/git `HEAD~300..HEAD` (139,492 body lines): 0.108 s for every hunk, the
      slowest 0.84 ms, against `--word-diff=porcelain`'s 0.454 s for git alone (0.210 s plain) —
      and porcelain is a second output format with no hunk bodies to stage from. The hunk body is
      unchanged, so **word highlights never affect staging**. App-wide `@AppStorage`, on by
      default.
    - **Context is `--unified=N` appended after the pinned `--unified=3`** (git takes the last,
      measured); Whole File is `--unified=2147483647`, one hunk per file.
    - **Staging and discarding always act on the standard diff.** The engine already guarantees
      it: `stageHunks`, `stageLines`, `discardHunks`, `discardLines` and their unstage twins re-list
      hunks with the pinned flags only (the sync `listHunks`, untouched), and a hunk id is a hash
      of path and body — so an id from a `-w` or `-U10` listing names nothing there and is refused
      (`StagingError.unknownHunkIDs`, pinned by a test), and an id that does match names a
      byte-identical hunk. The view adds the visible half: **with any option but the standard
      ones, Stage/Unstage Hunk and Discard Hunk… are disabled, lines are not selectable, and the
      bar reads "Hunks and lines can’t be staged or discarded" with a Reset button** — enabled
      again only once a standard listing has loaded, not merely once the options are standard.
      File-level Stage, Unstage, Discard Changes… and the section buttons stay: they act on paths,
      not on the diff. Rejected: mapping a filtered selection back onto the standard hunks (a
      `-w` context line is the *new* text, so the two bodies do not correspond line for line), and
      staging with the options (a `-w` hunk does not `git apply` — measured, "patch does not
      apply").
    - **Ignore Whitespace and Context are per view, in `@State`, not persisted.** Anything but the
      standard options turns staging off, and a hidden-whitespace setting that outlived the look
      it was for would leave a later session with disabled buttons and changes it cannot see.
      Word highlights change nothing but tint, so they persist app-wide, as the branch map's
      recency window does (decision 29).
    - **Engine surface**: `DiffOptions` (`ignoresWhitespace`, `contextLines`) as `options:` on the
      async `listHunks`, `commitDiff` and `stashDiff`, default `.standard` — which appends no flag,
      so every existing caller and the config-immunity sweep see the same argument vector. No CLI
      flag in this pass.

43. **The CLI gains `switch`, `tag --delete`, `file-history`, `blame`, `fetch <remote>` and `remote
    list|add|set-url|rename|remove|prune` — thin arms over the engine decisions 38, 39 and 41 built,
    in decision 37's shape.** Decided 2026-09-30 in the planning pass for umbrella **#0543**, with
    high confidence; every bullet is cheap to reverse, and #0543 carries the questions for Brennan.
    Prototyped end to end in a planning worktree: every arm compiled, the full suite passed with the
    whole set applied, and each named mutation turned its suite red.

    - **Grammar, git's spelling.** `switch (<branch> | --track <remote-branch> | --detach <commit>)`
      — `git switch`'s own verb and flags, not `checkout`; `--track origin/x` makes `x`, as git
      does. `tag --delete <name>`: git's long flag, because **`tag delete v1` already means "create
      a tag named `delete` at `v1`"** (#0363's grammar) and must keep meaning it; `--delete` takes
      exactly one name and no create flag. `file-history <path> [--revision <rev>]` and `blame
      <path> [--revision <rev>] [--lines <start>,<end>]` — a new verb rather than `log --follow`,
      because `log`'s payload is `CommitLog` entries and a file's history carries a per-commit
      status and previous path: one command, one payload shape. `fetch [<remote>]` — the existing
      verb with one optional positional. `remote (list | add <name> <url> | set-url <name> <url> |
      rename <old> <new> | remove <name> | prune <name>)` — a subcommand required, as `stash`;
      git's own subcommand names, `list` for git's bare `git remote`. No `remote` subcommand takes a
      flag. `--` ends the flags before a path that starts with `-`; a `--revision` value that starts
      with `-` is refused (git would read it as an option).
    - **Paths are repository-relative and literal**, as decision 37's. `file-history` runs `git
      --literal-pathspecs log --follow`: without it `*.txt` followed every `.txt` file (measured,
      git 2.54.0), and the app's inspector gains the same guarantee. `--lines` is two bare positive
      integers, start ≤ end; git's other `-L` forms are not accepted.
    - **Payloads.** `switch` `{head, branch?, operation}` (`switch`, `switch-track`,
      `switch-detach` — the operation `undo` then names); `tag --delete` the existing `Tag.Result`
      `{ref, oid, annotated}` for the ref it deleted; `file-history` `{path, revision,
      commits:[{oid, author, authorTime, subject, status, path, previousPath?}]}`; `blame` `{path,
      revision?, lines:[BlameLine]}`; `fetch <remote>` the existing `{remotes:[name]}`; `remote
      list` `{remotes:[{name, fetchURL?, pushURLs}]}`, `add`/`set-url` `{remote, undoable}`,
      `rename` `{name, previousName, trackingBranches, upstreamOf, undoable}`, `remove` `{removed,
      trackingBranches, upstreamOf, undoable}`, `prune` `{remote, pruned, undoable}`.
    - **Decision 41's journaling is in the payload, not only in the docs.** Every `remote` mutation
      carries `undoable`: `false` for `add` and `set-url` (configuration, never journaled) and for
      `rename` and `remove` (a marker entry `undo` refuses to cross, exit 6 — measured through the
      CLI: after `remote remove origin`, `undo` exits 6 naming `remote-remove` and no
      `refs/remotes/origin/*` comes back); `true` for `prune`, journaled first so `undo` restores
      the pruned branches (measured). `undo`'s exit-6 text names the remote rename or removal
      beside the push. `switch` and `tag --delete` are one journal entry each, which `undo`
      reverses (measured).
    - **Exit codes from the error**, decision 37's `engineFailure`: a `Checkout.Refusal`, an
      unknown tag, a `RemoteConfig.Refusal` and every `git` failure are 6. **`tag --delete` uses it
      too, although `tag`'s create path still flattens to 4** (#0497 question 4) — a new path
      starts with the rule the new verbs follow. A switch refused for local changes is exit 6 with
      the files in the message and nothing journaled; there is no `--merge`, no discard, no
      automatic stash (decision 38's rule; an agent runs `stash push` itself).
    - **Synchronous twins** for `FileHistory.run`, `RemoteSync.fetch(remote:)` and
      `RemoteSync.prune(remote:)`, for decision 37's reason: `runEngineCommand` is synchronous.
      Same arguments, same checkpoints, same refusals.
    - **Routing unchanged**: four new `CommandRegistry` names (`switch`, `file-history`, `blame`,
      `remote`; 40 → 44), each `.remote` over XPC to the app's `runEngineCommand`. `tag` and `fetch`
      keep their entries with new usage lines. Tests run each arm in-process against fixtures,
      remotes as bare repositories in a temporary directory; URLs added by `remote add` are
      `https://example.invalid/…`, which nothing contacts.
    - **Out of scope, filed as questions in #0543:** `switch --create`, choosing the local name for
      `--track`, `switch -` (the previous branch), deleting a remote branch, a push URL on
      `set-url`, history search over the CLI (decision 40's scopes — `log` would need flags), and
      `--follow` on `log` itself.

44. **A large repository stays fast: the History pane's chips, commit lookup and filter text are
    derived once per load into a `HistoryIndex`, off the main actor, and never in `body`; a
    window's six reads run at once.** Decided 2026-09-30 in the planning pass for umbrella
    **#0551**, with high confidence; prototyped end to end in a planning worktree (index, loader,
    wiring, VM spike on a 6,002-commit fixture). #0551 carries the questions for Brennan.

    - **Why this, over the next two candidates.** The ask was a daily driver for someone coming
      from GitUp, whose defining property was speed on large repositories — and this was the only
      candidate with a *measured* defect. On git/git (5,000 loaded commits, 1,017 refs) the loads
      were already fast (history 0.17 s, graph 0.06 s, sidebar 0.13 s, `BranchMapLayout.make` 3
      ms), but `CommitHistoryView.body` rebuilt every commit's ref chips against the whole ref list
      on each evaluation (42-46 ms release, 731-770 ms debug; O(commits × refs)) and, while a
      filter query was typed, ran Foundation's case-insensitive search over every commit (118-154
      ms more) — on the main actor, re-run on every `ContentView` update because the view is
      handed fresh closures. In the VM (debug build, #0555's 6,002-commit, 1,000-tag fixture)
      typing `rel-5994` into the filter took 17.05 s to reach "1 match" and `needle` 13.72 s to
      reach "20 matches"; with this decision applied, 2.18 s and 2.23 s. **The commit composer** (subject/body split,
      50/72 guides, co-author trailers, recent messages) is the runner-up: used on every commit,
      but polish on a working flow with no measured defect, and it has real design questions
      (where a body guide draws in a `TextEditor`, what "recent" means) that would go to Brennan.
      **A batch of the umbrellas' cheap follow-ups** (the sidebar filter only in the Commits scope,
      the "Switching…" line behind the alert, Add Remote in a menu) is third: each is small and
      cosmetic, and together they fix nothing a user is blocked on.
    - **What is built once.** `HistoryIndex(entries:refs:)` — `chipsByOid` (`RefChips.make` itself,
      handed only the refs at that commit, refs grouped by oid once: O(commits + refs)),
      `entriesByOid`, and per commit the folded message, author and chip names. 7.4-8.6 ms release
      / 19.5 ms debug on git/git, once per load. `CommitHistoryView` takes it as a **required**
      `index:` and reads it; its `body` builds none of it.
    - **Where it lives.** `loadRepositoryWindow(at:)` (`@concurrent`) builds it from the history
      and refs it just read, and `ContentView` assigns `historyIndex` only alongside `history` and
      `sidebar`, from that load — in `reload()` and `refreshAfterMutation(select:)`. Never from
      `body` (swift-guidance: view construction is pure) and never in `onChange` of the inputs
      (one writer, event-origin). A rerere forget reloads the sidebar alone and keeps the index:
      it touches no ref.
    - **The filter is a folded byte search.** Text and query are folded with
      `String.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)` into UTF-8
      bytes, and `memmem(3)` tests containment: 1.0-1.8 ms per query on git/git (from 118-154 ms).
      Same answers as the Foundation search on 19 of 20 queries tried; **`ß` differs**, and the
      folded answer is the right one — Foundation matched `ß` against a lone `s`, folding expands it
      to `ss`. `HistoryFilter.matches` (one commit) runs the same code, so the two cannot drift.
      Chip names are folded the same way; the sidebar keeps `RefFilter`.
    - **A window's reads run at once.** `reload()` and `refreshAfterMutation(select:)` awaited
      six independent `@concurrent` loaders in sequence — 0.62-0.68 s on git/git — on open and
      after **every** in-app mutation. Under `async let` in `loadRepositoryWindow` they take
      0.20-0.21 s. Only the summary's failure throws; the other five fall back as before (an
      unborn branch's unreadable log is an empty history). Every pane now appears together.
    - **Not in this decision:** paging past History's 5,000 commits (#0405) — the next step if
      5,000 is not enough; per-row rendering cost while scrolling (a `LazyVStack` of `Canvas`
      strips, not measured in-app — an Instruments question); the sidebar's per-render tag sort;
      the Whole File diff of a very large file (#0534 question 4). The VM spike records its
      timings as attachments and asserts none (CLAUDE.md).

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

1. ~~**Rebase engine scope.** GitUp wrote its own. How much of one does M5 actually require, and
   can `absorb` and `split` be built on narrower primitives?~~ **Answered — settled 2026-09-09, no
   rebase engine: M5 history rewriting is a pipeline over `commit-tree`, `cherry-pick` and
   `update-ref --stdin`, wrapped in `JournalCheckpoint.around`.** Original text kept for context.
   Decision, measured ground and per-command costs in
   [rebase-engine-decision.md](rebase-engine-decision.md). Filed as **#0060**; built on by
   #0061–#0063.
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
7. ~~**Does `RefSnapshot` grow a delta application — `apply(from:to:)` — alongside whole-snapshot
   restore, or stay snapshot-only?**~~ **Answered 2026-09-09 — Brennan: stay snapshot-only.** Raised
   2026-08-17: four M2 issues (#0231, #0232, #0248,
   #0251) each papered over one seam of "apply this whole snapshot" being restore's primitive
   (see [clean-room/snapshot-and-undo.md](clean-room/snapshot-and-undo.md)'s addendum). Prepared with measured evidence in
   [restore-delta-decision.md](restore-delta-decision.md) (filed as **#0258**, M5): of the three
   rules a delta was expected to dissolve,
   #0248's skip genuinely does, #0232's third-value discriminator and #0251's leave-alone survive
   unchanged, and #0231's non-deletion becomes the delta's own defining constraint. The decision:
   **stay snapshot-only**; a delta may be grown additively only on the named reversal trigger
   (a fifth seam instance needing a new scope rule, or the no-op-write refusal becoming a real
   two-agent cost), and it would be non-deleting, traversal-only. Original text kept for context.
8. ~~**Are SHA-256 repositories supported?**~~ **Answered 2026-09-09 — Brennan: out of scope,
   refuse cleanly.** Raised by the M1 milestone review's eleventh pass
   (2026-08-18), prepared by **#0308**. Measured on git 2.50.1 with a real `--object-format=sha256`
   fixture: `graph` throws (`RevListParser` requires a 40-character oid) and `absorb --dry-run`
   throws (the blame parser has the same check) while ten other engine commands — including the
   mutating core — work untouched, and `BlameLine.uncommittedOID`'s 40-zero sentinel can never
   match SHA-256's 64-zero uncommitted oid. The decision: **out of scope** — the follow-up change
   is one `rev-parse --show-object-format` detection at the `graphRows` and absorb blame entries,
   one typed refusal naming the algorithm, and two 64-hex test rows (enumerated in
   [sha256-decision.md](sha256-decision.md)); it ships as its own issue rather than inside #0308.
   Original text kept for context.

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
