# Journal capture policy

Settles guide §11's open question: how much uncommitted state a journal entry captures, and what
`undo` promises when it did not capture everything. Written for #0072; implemented by #0027.

**Decision: capture everything, always, except ignored files.** Record what was captured in the
entry, and let `undo` report honestly rather than guess.

---

## Why "always" rather than "when the operation would disturb it"

The tempting policy is to snapshot the worktree only for operations that would touch it, since refs
and the index are cheap and the worktree is not. Rejected, for three reasons:

1. **"Would disturb it" is a prediction, and predictions are wrong under conflict.** A rebase that
   was expected to replay cleanly touches the worktree the moment it conflicts. A policy that
   decided not to capture has already lost by the time it finds out.
2. **The failure is silent.** An operation that did not capture and did not need to is
   indistinguishable, at restore time, from one that did not capture and should have. The user
   learns about it when their work is gone.
3. **The cost is smaller than it looks** — see below.

The asymmetry decides it: over-capturing costs a few objects that `gc` later reclaims; under-capturing
costs the user's uncommitted work.

## What "everything" means, precisely

| State | Captured by | Notes |
|---|---|---|
| Refs and `HEAD` | `for-each-ref` + `symbolic-ref`, stored as a blob | Cheap, always |
| Index | `write-tree`, or the index file as a blob when unmerged | `write-tree` refuses an unmerged index |
| Tracked modifications | `git stash create` | Does **not** touch the stash stack |
| **Untracked, non-ignored files** | **A separate tree, built explicitly** | See the correction below |
| Sequencer state (`rebase-merge/`, `rebase-apply/`, `sequencer/`) | Copied per-worktree | Needed to resume a rebase after restore |
| `refs/rewritten/*` | With the ref set | Per-worktree; interactive-rebase label state |
| **Ignored files** | **Not captured** | Deliberate — see below |

### The `stash create` correction

**Verified on git 2.50.1:** `git stash create --include-untracked` and `git stash create -u`
**silently ignore the flag** and produce a 2-parent commit containing tracked modifications only.
Only `git stash push -u` produces the 3-parent form that includes untracked files, and `push` mutates
both the worktree and the stash stack, so it cannot be used for snapshotting.

Untracked files therefore need their own capture: build a tree from the untracked non-ignored paths
using a temporary `GIT_INDEX_FILE`, `write-tree` it, `commit-tree` the result, and store that OID in
the entry beside the stash commit.

This was the design's most dangerous assumption. Left in place, every journal entry would have
claimed to capture the worktree while dropping every untracked file — and an agent's newly written,
not-yet-added source file is exactly an untracked file.

### Why ignored files are excluded

Ignored files are excluded on purpose, not by oversight. `node_modules`, `.build`, `DerivedData`, and
`Pods` are ignored precisely because they are regenerable, and capturing them would make a snapshot
cost gigabytes and seconds instead of kilobytes and milliseconds.

This is what makes "always capture" affordable: the cost is bounded by *changed tracked files plus
untracked non-ignored files*, which in a working repository is small, not by the size of the working
tree.

**The entry records this**, so `undo` can say so rather than implying a fidelity it never had.

## What `undo` promises

The entry's `captured` object is the contract. `undo` reports, in structured output:

- **Restored**: every piece present in `captured`.
- **Not captured**: ignored files, always — named as a category, not silently omitted.
- **Refused**: when the guard fires, naming the ref, expected value, and actual value.

`undo` never reports success for something it did not restore. If `captured.worktree` is absent —
because the entry predates a policy change, or the capture failed — `undo` says the worktree was not
restored rather than leaving the user to discover it.

## Escape hatch

`switchyard checkpoint --include-ignored` exists for the case where a user genuinely wants a byte-exact
snapshot of a large tree, and it is never the default and never used by auto-checkpointing. Automatic
capture before every mutating command must stay cheap enough that nobody turns it off.

## Consequences for other issues

- **#0027** must implement untracked capture separately and test the round trip. Its done-criteria
  have been updated.
- **#0028**'s `captured` object needs a field per piece above, including an explicit
  `ignoredFilesExcluded: true`.
- **#0034**'s `undo` output must include the "not captured" report.
- **#0035** must include an untracked file in its round-trip fixtures, or this regresses invisibly.
