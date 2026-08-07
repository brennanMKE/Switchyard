# Switchyard

A SwiftUI git client for macOS with an agent-facing command-line tool, built for a world where a
coding agent is a first-class user of the repository alongside a human.

The name is a railyard: commits are cars, and the app's job is shunting them into a different order
safely. **Every mutating operation is reversible.**

> **Status: pre-alpha.** The repository currently holds a stock SwiftUI template, the design
> documents in `docs/`, and the task breakdown in `issues/`. Nothing described below is built yet.
> Work starts at [Milestone 0](docs/switchyard-development-guide.md#9-milestones), an engine spike
> that settles libgit2 packaging, commit signing, graph performance, and reftable compatibility
> before any app code is written.

## Two products, one engine

| Product | What it is |
| --- | --- |
| **Switchyard.app** | SwiftUI macOS app. Interactive commit graph, three-way merge, review UI. |
| **`switchyard`** | CLI. Structured, non-interactive git operations for humans and agents. |

`switchyard` ships inside the app bundle and symlinks into `/usr/local/bin`. It is a **companion to
the app, not a replacement for it**: the app owns the git engine, and the CLI drives it over XPC. If
the app is not running, the CLI launches it and waits, so the first command after a reboot still
works. What the CLI gives an agent is a structured, scriptable surface onto the same engine the human
is looking at — not a second implementation that can drift from it.

## The app

**Window → Tabs → Git View.** Tabs are the default navigation model, built on
[SlidingTabs](https://github.com/brennanMKE/SlidingTabs), and multiple windows are supported from
the start — each window holds its own set of repository tabs.

```
┌────────────────────────────────────────────────────────┐
│ [Switchyard ●] [Batty] [RemoteControl]            [+]  │
├────────────┬─────────────────────┬─────────────────────┤
│ Branches   │   ● main            │  diff of the        │
│  main      │   │╲                │  selected commit    │
│  feature/x │   ● ●               │                     │
│            │   │╱                │  + hunks            │
│ Worktrees  │   ●                 │  - lines            │
│  agent-a   │   │                 │                     │
│ Stashes    │   ●                 │                     │
└────────────┴─────────────────────┴─────────────────────┘
   Sidebar          Graph                 Detail
```

**One tab per repository, identified by `$GIT_COMMON_DIR`.** Opening a repository that is already
open focuses its tab rather than duplicating it, and opening a linked worktree focuses its parent
repository's tab and selects that worktree in the sidebar — so a project is always exactly one tab,
however you arrive at it.

## What it is for

Three things, in order of how much they matter:

**1. Structured repository state in one call.** An agent today spends four or five `git` invocations
and fragile text parsing to answer "where am I." `switchyard whereami` returns one JSON object: branch,
upstream, ahead/behind, in-progress rebase or merge or cherry-pick, stash count, dirty paths,
conflict count, signing config.

**2. Journaled undo.** GitUp's most valuable property, and the reason an agent can be left to run
unsupervised. A journal entry snapshots repository state *before* a semantic operation rather than
diffing what changed, so undo works for rebases and merges where an inverse operation is
ill-defined. Snapshots are real git objects held alive by refs under `refs/switchyard/journal/` —
nothing lives outside the repository, and `gc` cannot eat them.

**3. Human-in-the-loop over XPC.** An agent can push a diff or a question into a real macOS UI,
block on a human decision, and receive the answer as structured data:

```sh
switchyard review --staged --wait --json
# blocks while a human reviews in Switchyard.app, then:
# {"schemaVersion":1,"decision":"approve","comments":[…],"editedPatch":"…"}
# exit 0 on approve, 7 on reject
```

No other git tooling does this. It is the differentiator, and it is only possible because of the
XPC transport carried over from [RemoteControl](#relationship-to-remotecontrol).

Plus one thing GitUp never got: **commit signing**, SSH and GPG.

## Designed for agents

The CLI *is* the agent interface. Its contract:

- **`--json` on every command**, with `"schemaVersion": 1` in every response. Human-readable output
  is a courtesy; JSON is the contract. Agents break on inconsistent output shapes far more often
  than on missing features.
- **Errors are structured too** — `{"schemaVersion":1,"ok":false,"error":{"code":…,"message":…,"hint":…}}`
  on stdout, not a bare string on stderr.
- **Nothing is interactive unless the command name says so.** No editor spawning, no pager, no
  prompt. A command that needs the app and cannot reach it fails with exit code 3 naming what is
  missing — it never silently falls back, because an agent would then proceed without the human
  approval it was told to obtain.
- **Every mutating command auto-checkpoints**, so `switchyard undo` works whether or not the caller
  thought to ask.
- **Provenance trailers.** `switchyard commit --agent <name> --model <id> --session <id>` records who
  actually wrote a commit, following the `Co-authored-by` convention so existing tooling ignores it
  gracefully. A *signed* commit carrying provenance trailers is a meaningfully stronger claim than
  an unsigned one; no other client offers it.

### Teaching an agent to use it

Switchyard ships an **agent skill** — a markdown document describing the command set, the JSON
schemas, and the workflows worth knowing — packaged for [Claude
Code](https://claude.com/claude-code) and [OpenCode](https://opencode.ai), with a plain-markdown
form for anything else. It is generated from the same command metadata that produces `--help`, so it
cannot drift from the binary.

**There is deliberately no MCP server.** An always-loaded MCP tool surface costs context in every
session whether or not git comes up, while a skill costs approximately nothing until the agent needs
it. Client-side tool search and deferred schema loading have narrowed that gap, so the decision is
worth re-measuring rather than treating as permanent — but a shell tool an agent already knows how
to call, plus a document teaching it the flags, is the cheaper default. The JSON contract is
designed so an MCP wrapper would be a thin dispatch layer if that changes.

## The command set

Full detail in the [development guide](docs/switchyard-development-guide.md#6-the-switchyard-cli). In brief:

| Group | Commands |
| --- | --- |
| **Read** | `whereami`, `graph`, `log`, `status`, `hunks`, `conflicts`, `blame`, `verify` |
| **Rewrite** | `commit`, `fixup`, `absorb`, `split`, `reword`, `reorder`, `drop`, `stage`, `unstage` |
| **Undo** | `checkpoint`, `undo`, `redo`, `journal`, `restore` |
| **Worktrees** | `wt list`, `wt new`, `wt rm`, `wt where`, `wt gc`, `wt repair` |
| **Hooks** | `hooks install`, `hooks uninstall`, `hooks status` |
| **Human-in-the-loop** *(needs the app)* | `review --wait`, `ask`, `resolve --interactive`, `watch` |

Three worth calling out. **`switchyard hunks`** returns stable hunk IDs, which is what makes precise
agent-driven staging possible without `git add -p` — the interactive command agents cannot use.
**`switchyard absorb`** distributes staged hunks into the correct prior commits by matching each hunk
against the commit that last touched those lines; it is the highest-leverage way to clean up an
agent's messy branch. And **`switchyard wt new --agent <id>`** creates an isolated worktree for an agent
session, populated from a repo-level template — because a fresh worktree has the tracked files and
nothing else, and an agent whose first command dies on a missing `node_modules` starts improvising.

### Worktrees as the unit of agent isolation

One agent, one worktree, one branch, one checkout. Git already enforces that two worktrees cannot
have the same branch checked out, which makes it free mutual exclusion between agents rather than
an obstacle to work around. Switchyard treats worktrees as a primary object in both the app and the
CLI, tracks which agent session holds which worktree, and can tell you what a sibling agent is
working on without leaving your own checkout.

## Relationship to GitUp

Switchyard is a **clean-room reimplementation**, not a port.

[GitUp](https://github.com/git-up/GitUp) is copyright 2015-2018 Pierre-Olivier Latour and licensed
under **GPL v3**, GitUpKit included. Switchyard is **MIT** (see [LICENSE](LICENSE)), which makes the
separation strict rather than optional: no GitUp source is copied into this project in any language,
no Objective-C is translated line-by-line into Swift, and no GitUp test fixtures are reused.

What GitUp legitimately provides is *understanding of the problem*: why a snapshot-based undo model
beats a command history, why commit-DAG lane assignment is harder than it looks, and why a
sufficient rebase engine had to be written rather than taken from stock libgit2. Where a GitUp idea
informs a design decision here, the idea is written up in `docs/` in the author's own words and
implemented from that note.

GitUp remains the best interactive git client the Mac has had. Switchyard is not trying to replace
all of it — the v1 wedge is **journaled undo plus `review --wait`**, and nothing else on the Mac has
that pair.

## Relationship to RemoteControl

[RemoteControl](https://github.com/brennanMKE/RemoteControl) is a prototype by the same author, MIT
licensed, that validated exactly the transport Switchyard needs: long-lived, bidirectional IPC
between a CLI and a running SwiftUI app over `NSXPCConnection`. Its code and documentation are
reused directly here.

The shape, briefly: a plain double-clicked app cannot publish a named Mach service, because
`NSXPCListener(machServiceName:)` only works when launchd owns the name. So a small launch agent
embedded in the bundle declares the name and acts as a bootstrap broker. The app registers its
anonymous listener endpoint with the broker; `switchyard` connects to the broker by Mach service name,
receives the endpoint, then connects **directly** to the app. After the handoff the broker is out of
the data path, and restarting it does not disturb an attached session.

## Building

Requires Xcode 26 and macOS 26.

```sh
# Unsigned compile check — the default for ordinary work
xcodebuild build -project Switchyard.xcodeproj -scheme Switchyard \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet

# Unit tests
xcodebuild -project Switchyard.xcodeproj -scheme Switchyard \
  -destination 'platform=macOS' -only-testing:SwitchyardTests test
```

No Developer ID certificate and no notarization are needed to build and run locally — a locally
built app carries no `com.apple.quarantine` attribute, so Gatekeeper never evaluates it.

## Documentation

| Document | Covers |
| --- | --- |
| [docs/switchyard-development-guide.md](docs/switchyard-development-guide.md) | Scope, architecture, the full CLI surface, the journal model, milestones, settled decisions and open questions |
| [docs/switchyard-git-internals-and-undo.md](docs/switchyard-git-internals-and-undo.md) | How the journal works against git's on-disk state, the hook layer, and worktree support in detail |
| [CLAUDE.md](CLAUDE.md) | Working agreements for coding agents: licensing rules, signing safety, build commands, known traps |
| [docs/local-ai-workflow-log.md](docs/local-ai-workflow-log.md) | What went wrong running a local model as the implementer, and a checklist for starting the next project |
| `issues/` | Task breakdown, `NNNN.md` per task |

## License

MIT — see [LICENSE](LICENSE).
