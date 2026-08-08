# Switchyard: Git Internals, Undo, and Worktrees

Companion to [switchyard-development-guide.md](switchyard-development-guide.md). That document
defines scope and the CLI surface.
This one defines how the journal actually works against git's on-disk state, and how worktrees
are supported, which is a first-class requirement rather than an afterthought.

---

## 1. The rule that governs everything below

**Do not hand-parse `$GIT_DIR`.** Not the refs, not the index, not the reflog.

Git's own worktree documentation states the rule directly: <cite index="29-1">it is best not to look inside `$GIT_DIR` directly, and to use commands such as `git rev-parse` or `git update-ref` instead, which handle refs correctly. The rule of thumb is to make no assumption about whether a path belongs to `$GIT_DIR` or `$GIT_COMMON_DIR`, and to use `git rev-parse --git-path` to get the final path.</cite>

This is not conservatism. Three things break naive parsing today:

- **Loose refs, `packed-refs`, and now reftable.** <cite index="32-1">The default storage format for references in newly created repositories is changing from "files" to "reftable" in Git 3.0. A prerequisite is that alternative implementations including JGit, libgit2, and Gitoxide support it.</cite> Anything that reads `.git/refs/**` breaks completely on a reftable repository.
- **Index format variants.** Version 4 path compression, split index, untracked cache, and fsmonitor extensions all change the file's shape.
- **Worktrees.** `HEAD` lives in one place, `refs/heads/*` in another, and which is which depends on the ref name. Section 5 covers this.

So: `YardGit` reads state through libgit2 or through `git` plumbing, never through `FileManager`.
The one exception is watching for change notifications (Section 4), where the path is used as a
signal to re-read, never as a source of truth.

### The reftable problem is a live risk to the engine decision

This deserves to be escalated into Milestone 0 as a fourth question. <cite index="31-1">libgit2 did not support the reftable storage format introduced in Git 2.45, which meant git operations in dependent applications appeared broken for any repository using `--ref-format=reftable`. Zed removed its libgit2 dependency in June 2026 and replaced it with the git CLI, partly for this reason.</cite> Reftable support has since been merged into libgit2, but "merged" and "in a tagged release you can build against on macOS" are different states.

**M0 must verify**: create a repository with `git init --ref-format=reftable`, then confirm the
chosen libgit2 build can enumerate refs, resolve `HEAD`, and read the reflog in it. If it cannot,
the graph engine has to go through `git for-each-ref` and `git rev-list` instead of libgit2, and
the hybrid boundary from the main guide shifts substantially toward the CLI. Better to learn that
in week one.

---

## 2. Where git keeps the state that undo has to capture

Restoring a repository to a prior point means restoring all of the following. Anything omitted is
a silent data loss bug.

| State | How to read it | Notes |
| --- | --- | --- |
| `HEAD` | `git rev-parse --git-path HEAD` | Per-worktree. Can be symbolic or detached. |
| Branch and tag refs | `git for-each-ref` | Shared across worktrees. |
| Remote-tracking refs | `git for-each-ref refs/remotes` | Shared. Changes on fetch. |
| Stash | `refs/stash` plus its reflog | Shared. The reflog is the stack. |
| Index | `git rev-parse --git-path index` | Per-worktree. Includes conflict stages 1/2/3. |
| Worktree files | filesystem | The expensive one. See Section 3. |
| Sequencer state | `rebase-merge/`, `rebase-apply/`, `sequencer/` | Per-worktree. An in-progress rebase or cherry-pick. |
| Merge state | `MERGE_HEAD`, `MERGE_MSG`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `ORIG_HEAD` | Per-worktree pseudo refs. |
| Per-worktree refs | `refs/bisect/*`, `refs/worktree/*`, `refs/rewritten/*` | See Section 5. |
| Config | `config`, and `config.worktree` when enabled | Rarely part of undo, but `switchyard` must read both. |

### What git already gives you, and why it is not enough

**The reflog** records every `HEAD` and branch movement, which is why `git reset --hard` is
usually survivable. It has three limits that make it unsuitable as Switchyard's undo mechanism:

1. It records ref movement only. The index and worktree are not in it.
2. It expires. Defaults are 90 days for reachable entries and 30 for unreachable, and `gc` acts
   on that without asking.
3. It is a log, not a transaction boundary. A rebase that moved a branch, rewrote twelve commits,
   and left `ORIG_HEAD` behind appears as a series of entries with no marker saying "these
   fourteen lines are one user-visible operation."

**`ORIG_HEAD`** holds exactly one prior position and is overwritten by the next operation.

Switchyard's journal exists to supply what these lack: a semantic operation boundary, a complete
state capture, and an expiry policy the user controls. Read the reflog anyway, as a recovery
source when the journal has nothing (Section 6), but do not build undo on it.

---

## 3. Journal design

### The mechanics, in git primitives

Every piece of a snapshot is a real git object. Nothing is invented.

**Refs and `HEAD`** are just a list of name/OID pairs. Capture with `git for-each-ref` plus
`git symbolic-ref HEAD` or its OID when detached. Store the list as a blob. Restore with
`git update-ref --stdin`, which is transactional: the whole batch applies or none of it does.

**The index**, including conflict stages, is captured with a tree written from a temporary index:

```
GIT_INDEX_FILE=<temp> git read-tree <current index>   # or copy the index file
git write-tree
```

Note the exception: `git write-tree` refuses to write an unmerged index. When conflicts are
present, snapshot the index file itself as a blob and restore it byte-for-byte. That is the one
place where copying a git file directly is correct, because the file *is* the state.

**The worktree** is captured with `git stash create`. It builds a stash commit from the current
worktree and index and prints its OID **without touching the worktree or the stash stack**, which is
what makes it usable for snapshotting.

> **Correction, verified 2026-08-06 on git 2.50.1.** An earlier version of this document claimed that
> `git stash create --include-untracked` captures untracked files too. **It does not.** `git stash
> create` silently ignores both `-u` and `--include-untracked`: it produces a 2-parent stash commit
> containing only tracked modifications. Only `git stash push -u` produces the 3-parent form that
> includes untracked files — and `push` mutates the worktree and the stash stack, so it is unusable
> here.
>
> Untracked files must therefore be captured **separately and explicitly**: build a tree from the
> untracked (non-ignored) paths using a temporary `GIT_INDEX_FILE`, `write-tree` it, and
> `commit-tree` the result, recording that OID alongside the stash commit. Anything less loses
> untracked files on restore without saying so, which is exactly the silent data-loss failure this
> section opens by warning about.

Restore with `git stash apply <oid>`, or `git read-tree` plus `git checkout-index` for a harder
reset — plus an explicit restore of the untracked tree.

So a full snapshot is: one blob of ref state, one tree or blob for the index, and optionally one
stash commit. All three are ordinary objects in the ODB.

### Anchoring, so `gc` cannot eat the snapshot

Objects unreferenced by any ref are garbage. Every journal snapshot writes a ref under
`refs/switchyard/journal/<entry-id>` pointing at the snapshot commit. That single ref keeps the
whole snapshot reachable, survives `git gc` and `git maintenance`, and is removed by pruning.

Use `refs/switchyard/` rather than anything under `refs/heads` or `refs/tags` so the entries never
appear in normal branch listings, never get pushed by a default refspec, and are trivially
identifiable. They will show up in `git for-each-ref` output, so `switchyard`'s own ref enumeration must
filter them.

### Persistence across launches, and where it lives

This is the advantage over GitUp, and it comes almost free once snapshots are real objects.
GitUp's snapshots cannot outlive the process because they are in memory. Switchyard's are in the
object database, so they survive a quit, a reboot, and `switchyard` running with the app closed.

> **Corrected 2026-08-07: they do NOT survive a clone.** This paragraph claimed "a different machine
> that clones the repo". Measured on git 2.50.1: a plain `git clone` copies **nothing** under
> `refs/switchyard/` — only `--mirror` does, because `clone` fetches `refs/heads/*` and `refs/tags/*`
> and nothing else. `git push`, `push --all` and `push --tags` are likewise clean of journal refs.
>
> That is the **right** behaviour and should not be changed — an undo journal is local history, and
> pushing another machine's checkpoints to a shared remote would be surprising at best. But the
> durability claim has to be stated accurately, because a design that assumed a colleague could undo
> your checkpoint after cloning would be built on something that does not happen.

**Split the storage by what it is:**

| Data | Location | Why |
| --- | --- | --- |
| Snapshot objects and anchor refs | the repository, `refs/switchyard/journal/*` | Objects cannot live anywhere else. Travels with the repo. |
| Entry metadata: operation name, timestamp, which worktree, what was captured, cross-tool guard values | `.git/switchyard/journal.json` | Belongs with the repo it describes. Repo goes away, metadata goes with it. |
| Repository registry, cross-repo recent operations, agent session records, UI state | `~/.local/state/switchyard/` | Not repo-specific. Survives repo deletion. Enables "what did I do everywhere today." |

Honor `XDG_STATE_HOME` with `~/.local/state` as the fallback. Your instinct on the path is right,
and it beats `~/Library/Application Support` here because `switchyard` runs in shells, CI, and agent
sandboxes where the Library path is awkward or absent. The app uses the same path.

**The trap to record now:** this only works while Switchyard.app stays unsandboxed. A sandboxed
app gets a container-relative home, and `~/.local/state/switchyard` from the app would become
`~/Library/Containers/co.sstools.Switchyard/Data/.local/state/switchyard`, silently diverging
from what `switchyard` sees. This is one more entry on the list of things that break if sandboxing is
ever reconsidered.

**The truth is always in the repository.** The state directory is an index and a convenience.
If it is deleted, `switchyard journal` must rebuild from `refs/switchyard/journal/*` alone, with
reduced metadata. Write that rebuild path early and test it, because it is what keeps the design
honest about which store is authoritative.

### Entry shape

```json
{
  "schemaVersion": 1,
  "id": "01J8X...",
  "operation": "fixup",
  "command": "switchyard fixup HEAD~2",
  "timestamp": "2026-08-06T18:22:31Z",
  "worktree": { "id": "agent-a", "path": "/Users/b/src/proj-agent-a" },
  "captured": { "refs": true, "head": true, "index": true, "worktree": "stash", "untracked": true },
  "snapshotRef": "refs/switchyard/journal/01J8X...",
  "guard": { "HEAD": "abc123...", "refs/heads/main": "def456..." },
  "agent": { "name": "claude-code", "session": "01J8W..." }
}
```

`captured` is what makes `undo` able to report honestly what it can and cannot restore.
`guard` is what makes it safe. Both are load-bearing.

### The cross-tool guard

An agent will run `git` directly in the same repository between two `switchyard` commands. Constantly.
Before restoring, compare every ref in `guard` against its current value. On mismatch, refuse with
exit 4 and name the ref, the expected value, and the actual one. Offer `--force` for the human,
never for a scripted caller.

### Pruning

Journal entries expire on a count limit and an age limit, both configurable, defaulting to
generous values since the marginal cost of a snapshot is a few small objects. Pruning deletes the
anchor ref and the metadata entry together; the objects then become unreachable and normal `gc`
reclaims them. Never call `git gc` from `switchyard`.

---

## 4. Observing changes made outside Switchyard

The journal covers what `switchyard` does. Something has to notice what `git` does, or the app's view
goes stale and the guard fires constantly with no explanation.

Git provides a purpose-built mechanism, and it is the single most useful hook for this project.

**`reference-transaction`.** <cite index="30-1">This hook is invoked by any Git command that performs reference updates, executing whenever a reference transaction is preparing, prepared, committed, or aborted, and it also supports symbolic reference updates. For each reference update in the transaction, the hook receives on standard input a line of `<old-value> SP <new-value> SP <ref-name>`.</cite>

> **The quotation above is wrong about the states, and is kept verbatim only because it is a
> citation.** git 2.50.1 emits **`prepared`, `committed`, `aborted`** — there is no `preparing`
> state. Measured 2026-08-07 by logging `$1` from a real hook. The stdin format in the same sentence
> *is* correct and was verified byte-for-byte with `od -c` on both `files` and `reftable`
> repositories: single `0x20` separators, `LF` terminated. A creation carries the all-zeros oid as
> old-value; a deletion carries zeros as new-value, and an unconditional `git update-ref -d` carries
> zeros as **old**-value too, so deletion must be decided on the new value alone.

That is every ref change in the repository, from any tool, batched by transaction, with old and
new values. It is exactly the event stream Switchyard needs. Install `switchyard hook ref-txn` as this
hook, have it record `committed` transactions into the journal as observed (not undoable) entries,
and forward them to the app over XPC if it is attached.

Two cautions:

- The hook's exit status is ignored **except in `prepared`**, where a non-zero exit aborts the
  transaction. So the handler must be fast and must never fail there. Do the real work on
  `committed`, return 0 immediately otherwise.

  **Corrected 2026-08-07 by measurement.** The paragraph above, and the citation with it, named a
  `preparing` state. git 2.50.1 emits **`prepared`, `committed`, `aborted`** and nothing else — a
  hook logging `$1` through a real commit shows `prepared`, `committed`, and `aborted` (git emits a
  routine zero→zero `AUTO_MERGE` transaction that aborts on every commit). The abort behaviour was
  demonstrated rather than assumed: `[ "$1" = prepared ] && exit 1` gives `fatal: ref updates
  aborted by hook`, exit 128, ref never created, on both `files` and `reftable` repositories.

  The safe reading is unchanged and is what the handler should implement: **`committed` does the
  work, everything else returns 0 immediately** — which is also robust to a future git adding a
  state this document does not know about.
- The hook runs on every ref update including the journal's own writes. Set an environment marker in `switchyard` and have the hook skip its own transactions, or the journal records itself recording itself.

**`post-rewrite`** complements it with the mapping git will not give you any other way. <cite index="30-1">It is invoked by commands that rewrite commits, currently `git commit --amend` and `git rebase`, and receives on stdin a list of `<old-object-name> SP <new-object-name>` lines. For squash and fixup operations, all squashed commits are listed as rewritten to the squashed commit, so several lines may share the same new object name, and commits are listed in the order rebase processed them.</cite>

Store that mapping in the journal entry. It is what lets Switchyard show a human "these four
commits became this one" after a rewrite, rather than just two different graphs.

**Also worth wiring:** `post-checkout` (fires on `git worktree add` too, unless `--no-checkout`),
`post-merge`, `post-commit`, and `post-index-change` for index writes.

**Hook installation is a user decision, not something `switchyard` does silently.** Repositories often
already have hooks, or use `core.hooksPath` pointing at a managed directory. `switchyard hooks install`
should detect existing hooks, chain rather than clobber, and be reversible with
`switchyard hooks uninstall`. Everything degrades to polling if hooks are declined.

**FSEvents** on `$GIT_COMMON_DIR` and each `$GIT_DIR` remains useful for the app's live view, and
you have prior experience with it. Treat it as a "something changed, re-read" signal only. It
cannot tell you what changed or in what order, which is precisely what
`reference-transaction` does give you.

---

## 5. Worktrees

Worktrees are the natural unit of agent isolation: one agent, one worktree, one branch, one
checkout, no interference. Switchyard should treat them as a primary object in both the app and
the CLI, not as an advanced feature buried in a menu.

### The layout, precisely

<cite index="29-1">Each linked worktree has a private sub-directory in the repository's `$GIT_DIR/worktrees` directory, usually named after the base name of the worktree's path, with a number appended if that name is taken. Within a linked worktree, `$GIT_DIR` points at this private directory and `$GIT_COMMON_DIR` points back at the main worktree's `$GIT_DIR`, and these settings are made in a `.git` file at the top of the linked worktree.</cite>

So for a main worktree at `/path/main` and `git worktree add /path/other/test-next next`:

- `/path/other/test-next/.git` is a **file**, not a directory, containing a `gitdir:` pointer
- `$GIT_DIR` inside it is `/path/main/.git/worktrees/test-next`
- `$GIT_COMMON_DIR` is `/path/main/.git`

<cite index="29-1">`git rev-parse --git-path HEAD` in the linked worktree returns `/path/main/.git/worktrees/test-next/HEAD`, while `git rev-parse --git-path refs/heads/master` uses `$GIT_COMMON_DIR` and returns `/path/main/.git/refs/heads/master`.</cite>

`YardGit` needs a `WorktreeContext` type resolved once per invocation holding the worktree path,
`$GIT_DIR`, `$GIT_COMMON_DIR`, and the worktree id. Every path lookup goes through it. No string
concatenation onto `.git/` anywhere in the codebase.

### Which refs are shared and which are not

This is the detail that makes journal restore correct or catastrophic.

<cite index="29-1">In general all pseudo refs are per-worktree and all refs starting with `refs/` are shared. Pseudo refs are ones like `HEAD` which sit directly under `$GIT_DIR` rather than inside `$GIT_DIR/refs`. The exceptions are refs inside `refs/bisect`, `refs/worktree`, and `refs/rewritten`, which are not shared.</cite>

Consequences for undo:

- Restoring `HEAD` affects **only the worktree the operation happened in**. The journal entry
  records which worktree, and restore refuses if run from a different one without `--worktree`.
- Restoring `refs/heads/*` affects **every worktree**. If another worktree has that branch checked
  out, its working copy is now inconsistent with its `HEAD`. The guard must check other worktrees'
  `HEAD` values, and `undo` must warn by name when a restore will disturb another worktree.
- `refs/rewritten/*` is per-worktree and holds interactive rebase label state. A journal snapshot
  taken mid-rebase must capture it or the rebase cannot be resumed after restore.

Reading another worktree's per-worktree refs is supported and does not require path games:
<cite index="29-1">per-worktree refs can be accessed from another worktree via the special paths `main-worktree` and `worktrees`, so `main-worktree/HEAD` resolves to the main worktree's `HEAD` and `worktrees/foo/HEAD` resolves to `$GIT_COMMON_DIR/worktrees/foo/HEAD`.</cite>
Use those. `git rev-parse worktrees/agent-a/HEAD` is the correct way for `switchyard` to answer "what is
agent A on right now."

### Branch exclusivity is a feature, not an obstacle

<cite index="29-1">`git worktree add` refuses to create a worktree when the commit-ish is a branch name already checked out by another worktree, unless `--force` is used.</cite>

For agentic workflows this is free mutual exclusion: two agents cannot be on the same branch at
once, and git enforces it. Switchyard should surface the refusal as a clear structured error
naming the worktree that holds the branch, and should never pass `--force` on an agent's behalf.

### Configuration traps

<cite index="29-1">By default the repository config file is shared across all worktrees. Worktree-specific configuration requires enabling `extensions.worktreeConfig`, after which specific configuration lives at the path given by `git rev-parse --git-path config.worktree`. Note that `core.worktree` should never be shared, `core.bare` should not be shared when true, and `core.sparseCheckout` should not be shared unless sparse checkout is always used for all worktrees.</cite>

Practical consequence: if Switchyard offers sparse worktrees for large repos (it should, see
below), it must enable `extensions.worktreeConfig` first, or one agent's sparse checkout silently
reshapes every other worktree. <cite index="29-1">Older Git versions refuse to access repositories with this extension</cite>, so it is a prompt to the user, not something `switchyard` turns on quietly.

Same category: <cite index="29-1">`worktree.useRelativePaths` set to true implies enabling `extensions.relativeWorktrees`, making the repository incompatible with older versions of Git.</cite> Relative paths are attractive for agent worktrees that get moved or containerized, but the compatibility cost is real. Offer it, default it off.

### Lifecycle, and the mess agents leave behind

An agent that crashes, or a container that is torn down, leaves a worktree directory gone and its
administrative entry behind. Git handles this, but only if asked. <cite index="29-1">If a working tree is deleted without using `git worktree remove`, its administrative files in the repository will eventually be removed automatically per `gc.worktreePruneExpire`, or `git worktree prune` can clean up stale administrative files.</cite> And <cite index="29-1">`git worktree repair` reestablishes connections when the main worktree or a linked worktree has been moved, by running repair in the main worktree, or within the moved worktree, or from any worktree with each tree's new path as an argument.</cite>

There is also a clever repurposing available. <cite index="29-1">`git worktree lock` prevents a worktree's administrative files from being pruned, and also prevents the worktree from being moved or deleted, with `--reason` explaining why.</cite> Its intended use is removable media, but "an agent session is live in this worktree" is an equally valid reason. `switchyard wt new --agent <id>` should lock with a machine-readable reason, and release on session end. It makes prune safe to run at any time and makes an abandoned session visible in `git worktree list --verbose`.

### Detection and listing

<cite index="29-1">`git worktree list --porcelain` emits a line per attribute with a label and value separated by a space, boolean attributes such as `bare` and `detached` appear as a label only when true, the first attribute of each record is always `worktree`, and an empty line ends the record. The `-z` form terminates lines with NUL rather than newline, which makes the output parseable when a worktree path contains a newline character.</cite>

Always use `--porcelain -z`. Agent-created worktree paths are machine-generated and will
eventually contain something awkward. <cite index="29-1">The porcelain format is documented as stable across Git versions and regardless of user configuration.</cite>

`switchyard wt list --json` should return the porcelain data plus what agents actually need: dirty
state, ahead/behind, whether a rebase or merge is in progress, the attached agent session, and
the journal entry count for that worktree.

### The unglamorous problem that actually breaks agent worktrees

A fresh worktree has the tracked files and nothing else. No `node_modules`, no `.env`, no
`Pods`, no build cache, no `.venv`. The agent's first command fails and it starts improvising.

This is the highest-value worktree feature Switchyard could ship and nothing does it well:

**Worktree templates.** A Switchyard-level config listing untracked paths to copy, symlink, or
regenerate on `switchyard wt new`, plus optional post-create commands. Symlink shared caches, copy
per-worktree secrets, run the bootstrap command once. Store it in the repo so the whole team and
every agent gets the same treatment.

Pair it with `--no-checkout` plus sparse checkout for large repositories, so an agent working on
one subsystem does not materialize the entire tree. <cite index="29-1">`--no-checkout` suppresses checkout specifically so customizations such as configuring sparse checkout can be made first.</cite>

### Worktree commands

| Command | Purpose |
| --- | --- |
| `switchyard wt list` | Structured superset of `worktree list --porcelain`, plus dirty state, ahead/behind, in-progress operation, attached agent, journal depth. |
| `switchyard wt new <name>` | Create a worktree. `--branch`, `--from`, `--detach`, `--agent <id>` (locks with a session reason), `--template <name>`, `--sparse <paths>`. |
| `switchyard wt rm <name>` | Remove, releasing the lock and the agent session. Refuses when unclean without `--force`, matching git. |
| `switchyard wt where` | Resolve the current context: worktree id, path, `$GIT_DIR`, `$GIT_COMMON_DIR`, main worktree path. |
| `switchyard wt gc` | `prune` plus reporting of prunable and abandoned-session worktrees. |
| `switchyard wt repair [<path>...]` | Wraps `git worktree repair` for the moved-directory case. |

And `switchyard whereami` gains a `worktree` object so an agent's first call tells it which worktree it
is in and whether any sibling is working the same branch.

---

## 6. Further features these docs surface

Ordered by value relative to effort.

**`rerere`.** Git can record how a conflict was resolved and replay that resolution when the same
conflict reappears. For agents this is directly valuable: a human resolves a merge conflict once
in Switchyard's three-way UI, and every subsequent rebase of that branch resolves it without
asking. `switchyard rerere status --json` to show what is recorded, and surface it in the app so the
recorded resolutions are visible and editable rather than invisible magic. This pairs naturally
with `resolve --interactive` from the main guide.

**`range-diff` after a rewrite.** After `fixup`, `absorb`, or a rebase, the question a reviewer
actually has is "what changed in the changes." `git range-diff` answers it, and the `post-rewrite`
mapping tells you exactly which ranges to compare. `switchyard rewrite-diff <journal-entry>` gives a
human the confidence to accept an agent's history rewrite instead of undoing it defensively.
This is the feature that makes the journal feel trustworthy rather than merely present.

**Notes for decisions, trailers for provenance.** Trailers change the commit SHA; notes
(`refs/notes/*`) do not. So agent provenance belongs in trailers, written at commit time and
covered by the signature, while review decisions, approval records, and `review --wait` outcomes
belong in notes, attached after the fact without invalidating anything. Both, for different
reasons. Document the split so it does not get relitigated.

**`commit-graph`.** A maintained commit-graph file is the difference between a graph view that
feels instant on a 50,000-commit repository and one that does not. `git commit-graph write
--reachable` is cheap and Switchyard can keep it fresh in the background. Fold this into the M0
performance measurement rather than treating it as an optimization for later.

**Cheap upstream drift check.** This is what the protocol-v2 document is good for, and it is
worth being direct that the rest of it is not relevant to undo. Protocol v2 exists so that
<cite index="28-1">reference advertisement is omitted unless explicitly requested, with an `ls-refs` command to explicitly request some refs</cite>, and <cite index="28-1">`ls-refs` accepts `ref-prefix <prefix>` arguments so that only references matching one of the given prefixes are shown, though this is purely an optimization and clients should filter the result themselves</cite>. That makes "has my branch's upstream moved" a single cheap round trip rather than a fetch. `git ls-remote` already speaks v2 and gives you this for free, which is one more argument for keeping the network path on the CLI. `switchyard upstream-status --json` lets an agent decide whether it needs to fetch before it starts rewriting.

Also from that document, <cite index="28-1">the `object-info` command retrieves information about objects, currently size, so a client can make decisions without fully fetching them</cite>. Relevant only if partial clone support becomes a goal.

**Automated bisect.** `git bisect run` with an agent-supplied test command is an unusually good
fit: the agent writes the predicate, git drives the search, Switchyard visualizes the narrowing on
the graph. `refs/bisect/*` is per-worktree, so a bisect can run in a dedicated worktree without
disturbing anything else. Speculative, but cheap to build on top of what M1 already needs.

**Lost commit recovery.** When the journal has nothing, `git fsck --lost-found` plus the reflog
can still surface orphaned commits. A browsable "unreachable commits" view is a small feature
that occasionally saves someone's afternoon.

---

## 7. Changes to the main guide — applied

These were folded into [switchyard-development-guide.md](switchyard-development-guide.md) on
2026-08-06. Kept as a record so the changes are not re-applied or mistaken for pending work.

| Change | Where it landed |
| --- | --- |
| M0 gains a fourth question: does the chosen libgit2 build work against a `--ref-format=reftable` repository? | §5 Milestone 0 spike, §9 M0 |
| M0's performance question measures with and without `commit-graph` | §5 Milestone 0 spike |
| M2 gains the hook layer: `switchyard hooks install`, `reference-transaction`, `post-rewrite` | §6 Hooks command group, §9 M2 |
| Worktrees move into M1, because `WorktreeContext` must precede all path resolution | §6 Worktrees command group, §9 M1 |
| `$XDG_STATE_HOME`/`~/.local/state/switchyard/` added to the identifiers table | §3 |
| Sandboxing gains the state-path divergence as a second concrete consequence | §11 open question 4 |

Also carried across beyond the six above: the "never read `$GIT_DIR` with `FileManager`" rule and
the reftable risk to the hybrid boundary (§5), the three-way storage split and the guard, worktree,
and rebuild-path notes in the journal section (§7), and test requirements covering reftable
fixtures, unmerged-index snapshots, real linked worktrees, and the state-directory rebuild (§10).

---

## Reference material

- git-worktree: https://git-scm.com/docs/git-worktree
- githooks: https://git-scm.com/docs/githooks
- gitrepository-layout: https://git-scm.com/docs/gitrepository-layout
- protocol-v2: https://git-scm.com/docs/protocol-v2
- reftable format: https://git-scm.com/docs/reftable
- Git breaking changes, including the reftable default: https://git-scm.com/docs/BreakingChanges
