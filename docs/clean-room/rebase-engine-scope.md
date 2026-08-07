# Rebase engine scope

**Written 2026-08-06, before #0060.** Understanding formed from: GitUp's README, which states it
"reimplements everything else on top of [a minimal subset of libgit2] (it has its own 'rebase
engine' for instance)"; git's documentation for `rebase`, `cherry-pick`, and `rerere`; and the
measured constraints in `docs/engine-findings.md`. GitUp's rebase implementation was not consulted.

## The problem

Switchyard's M5 commands — `absorb`, `split`, `reorder`, `drop`, `reword` — all rewrite history
non-interactively. `git rebase -i` cannot serve them, because it is built around opening an editor
on a todo list and an agent has no editor. Setting `GIT_SEQUENCE_EDITOR` to a script that writes the
todo file works, but it is a fragile shape: the operation's intent is encoded in a temporary file
whose format is not a stable contract, and failures surface as a half-finished rebase rather than a
structured error.

Stock libgit2 rebase is not sufficient either. It handles the mechanical replay but not the
history-editing semantics these commands need.

That is presumably why GitUp wrote its own. The open question — guide §11 — is **how much of one
Switchyard actually needs**, and whether `absorb` and `split` can be built on narrower primitives
instead.

## The narrower primitives

Most of what M5 needs decomposes into operations git already exposes non-interactively:

- **`commit-tree`** writes a commit from a tree and explicit parents, with no working-tree
  involvement. That is the whole of "make a modified copy of this commit".
- **`cherry-pick`** replays a commit onto a new base and reports conflicts structurally.
- **`read-tree` / `checkout-index`** manipulate the index without touching the working tree.
- **`update-ref --stdin`** moves the branch transactionally once the new chain exists.

A rewrite then becomes: walk the commits from the rewrite point to the tip, produce a replacement
for each with `commit-tree`, and move the ref once at the end. No todo file, no editor, no sequencer
state, and every intermediate object already in the ODB — which means a failure leaves the original
history untouched, because the ref never moved.

Under this framing:

- **`reword`** is one `commit-tree` plus replaying descendants. No merge machinery at all.
- **`drop`** and **`reorder`** are the same walk with a modified commit list, needing conflict
  handling only where the changed order actually conflicts.
- **`split`** needs the index manipulated at a hunk boundary, then two `commit-tree` calls — the
  hunk work is #0016's stable hunk IDs, not the rebase engine's.
- **`absorb`** is the one that genuinely needs replay, because inserting a change into an older
  commit forces every descendant to be recreated. Even so, that is `cherry-pick` in a loop with a
  known target list, not an interactive rebase.

## The recommendation to test in #0060

**Do not write a rebase engine. Write a rewrite pipeline over `commit-tree` and `cherry-pick`**, and
treat "we need more than this" as a finding that must be demonstrated by a specific command failing,
not assumed up front.

The reasons to prefer this: it is far less code, it reuses git's own conflict semantics rather than
reimplementing them, it produces structured errors instead of sequencer state, and — because signing
happens at commit creation (#0036) — signed commits stay signed naturally, since every rewritten
commit is created through the same path as an ordinary one.

The risk to watch: `rerere` (#0065) and conflict replay are where a hand-rolled pipeline is most
likely to diverge from what a user expects, because `git rebase` applies recorded resolutions
automatically. If replay semantics prove hard to match, that is the concrete evidence that would
justify more machinery.

## What to implement from this

`#0060` evaluates this against the M5 command list and records a decision. Its own done-criteria
require enumerating the minimum primitive set — this note is the starting hypothesis, not the answer,
and the answer must come from trying it.
