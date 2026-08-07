# Snapshot-based undo

**Written 2026-08-06, before #0027.** Understanding formed from: GitUp's README description of
"undo/redo and Time Machine like snapshots"; git's own documentation for `reflog`, `stash create`,
`update-ref --stdin`, `write-tree`, and `gitrepository-layout`; and the constraints in
`docs/switchyard-git-internals-and-undo.md`. GitUp's implementation was not consulted while writing
this, and it must not be consulted while implementing from it.

## The problem

A git client that rewrites history needs an undo that works for operations whose inverse is not
well-defined. Reverting a commit is easy. Reverting *a rebase that moved a branch, rewrote twelve
commits, and left the index half-staged* is not, because there is no single operation that undoes it
— and the obvious candidates are all wrong:

- **The reflog** records only ref movement. The index and the working tree are absent from it, it
  expires on a schedule the user did not choose, and it is a log rather than a transaction boundary:
  one user-visible operation appears as an unmarked run of entries.
- **`ORIG_HEAD`** holds exactly one prior position and the next operation overwrites it.
- **Computing an inverse** requires knowing what the operation did, which for a conflict-resolving
  rebase is not recoverable from the result.

## The insight

Do not invert the operation. **Capture the state before it, and restore that state.**

This works uniformly, which is the whole point: undoing a rebase, a merge, a fixup, and a stray
`reset --hard` are the same code path, because none of them is treated as an operation to reverse.
They are all "the repository looked like this; make it look like that again."

It also means correctness depends entirely on capture being *complete*. Anything not captured is
silently lost on restore, which turns an undo feature into a data-loss feature. So the capture list
is the design, and it is enumerated in `switchyard-git-internals-and-undo.md` §2 rather than left to
be discovered per-operation.

## Switchyard's approach

**Every piece of a snapshot is an ordinary git object.** Nothing is invented and nothing lives
outside the repository:

- **Refs and `HEAD`** are a list of name/OID pairs — read with `for-each-ref` plus `symbolic-ref`,
  stored as a blob, restored with `update-ref --stdin`, which is transactional so a partial restore
  is impossible.
- **The index** becomes a tree via `write-tree`. When it is unmerged `write-tree` refuses, so the
  index file itself is stored as a blob and restored byte-for-byte — the one place where reading a
  git file directly is correct, because the file *is* the state.
- **The working tree** uses `stash create`, which builds a commit from the working tree and index
  and prints its OID **without touching either or the stash stack**. This primitive is the reason
  worktree capture is cheap enough to do by default.

**Anchoring:** a ref under `refs/switchyard/journal/<id>` keeps the snapshot reachable, so `gc`
cannot reclaim it. Outside `refs/heads` and `refs/tags` so it never appears in branch listings and
is never pushed by a default refspec.

## Where Switchyard deliberately differs

**Snapshots persist.** GitUp's are in memory and cannot outlive the process. Switchyard's are real
objects in the object database, so they survive a quit, a reboot, a clone onto another machine, and
`yard` running with the app closed. This falls out of using git objects rather than being a feature
added on top — and it is what makes undo usable by an agent running headless.

**A cross-tool guard.** GitUp could assume it was the only writer. Switchyard cannot: an agent runs
`git` directly between two `yard` commands as the normal case. Every entry records the ref values it
expects, and restore refuses — naming the ref, the expected value, and the actual one — rather than
clobbering work it did not know about.

**Worktree awareness.** `HEAD` and the index are per-worktree; `refs/heads/*` are shared. Restoring
a branch ref affects every worktree that has it checked out, so an entry records which worktree it
came from and restore warns by name when it will disturb a sibling.

## What to implement from this

`#0027` builds the three capture primitives and their restores. `#0028` adds anchoring and entry
metadata. `#0031` adds the guard. None of them requires looking at GitUp, and none of them should.
