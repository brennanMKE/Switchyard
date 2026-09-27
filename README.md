# Switchyard

A SwiftUI git client for macOS with an agent-facing command-line tool, built for a world where a
coding agent is a first-class user of the repository alongside a human.

The name is a railyard: commits are cars, and the app's job is shunting them into a different order
safely. **Every mutating operation is reversible.**

> **Status: pre-alpha.** The app runs: it opens a repository and shows its history, branches and
> diffs, and it can edit history with journaled undo. The CLI's commands are built and tested in
> the engine, but reaching the app from `switchyard` over XPC currently needs a signed build
> (#0418 is making the unsigned local build work). Parts of this README describe the design in
> `docs/`, not the build — [What works today](#what-works-today) and
> [The command set](#the-command-set) are the current state.

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

## What works today

**Switchyard.app** opens a repository through the toolbar's Open button into a window with a
header — branch, ahead/behind its upstream, working-tree counts — over three panes. File ▸ Open,
Open Recent and drag-and-drop don't reach the window yet (#0416).

- **Sidebar** — local branches (current branch first, each with ahead/behind and merged state),
  remotes, tags, worktrees, a stash count and recorded rerere resolutions.
- **History** — the commit history drawn as a **branch map**: every branch tip on the top row under
  its label, each branch's commits down its own lane; commits reachable only from remote-tracking
  refs are dimmed. Clicking a branch in the sidebar scrolls to its tip.
- **Detail** — the selected commit's metadata, trailers and changed files, or the working tree's
  status. **Show Changes** opens the commit's files and diffs in a window of its own.

The toolbar's **Filter** field narrows the sidebar's refs and matches History commits by message,
ref name or hash prefix.

**Editing history** from a commit's context menu (and the Commit menu): Edit Message, Fixup or
Squash with Parent, Split, Swap with Parent or Child, Delete, Revert, Cherry-Pick, Merge into
Current Branch, Rebase onto Here, Set Branch Tip, Add Tag, Create Branch, Edit Local Branch. Every
one of them is journaled, and **Edit ▸ Undo / Redo** walks the journal.

Not there yet: one tab per repository (in progress), opening from File ▸ Open, Open Recent and
drag-drop (#0416), staging and committing from the app, and network operations.

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
- **Every mutating command is journaled**, so it can be undone from the app whether or not the
  caller thought to ask. (CLI `undo`/`redo` and provenance trailers on commits are designed in the
  guide, not built.)

### Teaching an agent to use it

Switchyard will ship an **agent skill** — a markdown document describing the command set, the JSON
schemas, and the workflows worth knowing — packaged for [Claude
Code](https://claude.com/claude-code) and [OpenCode](https://opencode.ai), with a plain-markdown
form for anything else. It will be generated from the same command metadata that produces `--help`
(`switchyard schema` already emits it as JSON), so it cannot drift from the binary.

**There is deliberately no MCP server.** An always-loaded MCP tool surface costs context in every
session whether or not git comes up, while a skill costs approximately nothing until the agent needs
it. Client-side tool search and deferred schema loading have narrowed that gap, so the decision is
worth re-measuring rather than treating as permanent — but a shell tool an agent already knows how
to call, plus a document teaching it the flags, is the cheaper default. The JSON contract is
designed so an MCP wrapper would be a thin dispatch layer if that changes.

## The command set

What `CommandRegistry.all` registers today (`switchyard schema` prints every command's flags, exit
codes and payload). Every command answers with the JSON envelope on stdout.

| Group | Commands |
| --- | --- |
| **Read** | `whereami`, `status`, `conflicts`, `hunks --staged\|--unstaged`, `log [<range>]`, `graph [--limit <n>]`, `verify <rev>`, `rewrite-diff <entry>`, `rerere status` |
| **Rewrite** | `absorb [--dry-run]`, `split`, `reword`, `drop`, `reorder`, `rebase-onto`, `set-tip` |
| **Integrate** | `revert`, `cherry-pick`, `merge --ff-only\|--no-ff` |
| **Refs** | `tag`, `branch create\|rename\|delete\|upstream` |
| **Worktrees** | `wt list`, `wt where` |
| **Human-in-the-loop** *(needs the app)* | `review --wait`, `ask`, `resolve --wait`, `watch` |
| **Local** | `--help`, `--version`, `schema`, `noop` |

**`switchyard hunks`** returns stable hunk IDs, which is what makes precise agent-driven staging
possible without `git add -p` — the interactive command agents cannot use. **`switchyard absorb`**
distributes staged hunks into the prior commits that last touched those lines; it is the
highest-leverage way to clean up an agent's messy branch.

Until the CLI reaches an unsigned app (#0418), `swift run yard-engine <command>` in `YardKit/` runs
the same engine commands in-process against the current directory — a development harness, not the
shipping CLI, and without the four human-in-the-loop commands.

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
# The app, unsigned — the default for ordinary work
xcodebuild build -project Switchyard.xcodeproj -scheme Switchyard \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet

# The Swift package — engine, views, CLI — and its tests
cd YardKit && swift build && swift test

# The development harness: engine commands in-process, no app
cd YardKit && swift run yard-engine whereami
```

Or open `Switchyard.xcodeproj` in Xcode and Run the `Switchyard` scheme.

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
