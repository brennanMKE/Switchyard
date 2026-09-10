# Rebase engine scope — decision

**Decided 2026-09-09 (issue #0060, round 1).** Milestone M5. Settles guide §11's open question on
rebase engine scope. The starting hypothesis was
[clean-room/rebase-engine-scope.md](clean-room/rebase-engine-scope.md), written 2026-08-06; GitUp's
rebase implementation was not consulted (GPLv3 — clean-room rules in CLAUDE.md §2).

## Decision

**Switchyard does not write a rebase engine.** The M5 history-rewriting commands (`reword`, `drop`,
`reorder`, `split`, `absorb`) are built as a **rewrite pipeline over git's non-interactive
primitives**:

- **`git commit-tree`** — creates the modified copy of a commit from a tree and explicit parents,
  with no working-tree involvement.
- **`git cherry-pick`** — replays commits onto a new base; its conflict reporting drives the
  exit-8 resumable contract (measured below, Probe 1).
- **`git update-ref --stdin`** — moves the branch ref once, transactionally, after all replacement
  objects exist. Until the ref moves, any failure leaves the original history untouched.
- The whole rewrite runs inside **`JournalCheckpoint.around`**, so undo reverses the entire rewrite
  as one step.

The evidence bar for ever growing more machinery is **a specific M5 command demonstrably failing
under this pipeline** — measured against the pipeline, not an assumption up front.

## The minimum primitive set, per command

| command | primitives it needs | replay? |
|---|---|---|
| `reword` | `commit-tree` + descendant replay | yes, trivial (no tree change) |
| `drop` | the same walk, commit list minus one | only where the gap conflicts |
| `reorder` | the same walk, reordered list | conflicts only where the new order actually conflicts |
| `split` | #0016 hunk IDs + index manipulation + two `commit-tree` calls | no replay beyond the split point's own descendants |
| `absorb` | #0018 range-limited blame + `cherry-pick` replay of descendants | yes — the one genuine replay consumer |

`absorb` is the one genuine replay consumer; `split`'s hunk work is #0016's stable hunk IDs and
index manipulation, not replay.

## Options compared

1. **Stock libgit2 rebase** — not linked at all since #0123/#0103's re-milestone; adopting it would
   resurrect the vendoring question for an engine the clean-room note already judged insufficient
   for interactive-style history editing (mechanical replay only). **Rejected.**
2. **Shell out to `git rebase -i`** with a scripted `GIT_SEQUENCE_EDITOR`. Costs: the operation's
   intent lives in a temporary todo file whose format is not a stable contract; failures surface as
   half-finished sequencer state rather than typed errors; and `GIT_SEQUENCE_EDITOR` is already
   pinned to `false` in `GitProcess` as a hazard guard — this route would have to unpin the guard
   added against exactly this shape. **Rejected as the general mechanism** (Fixup's `--autosquash`
   without `-i` remains the measured exception it is).
3. **Purpose-built engine** (GitUp's route) — the most code, and it reimplements conflict semantics
   git already owns: the conflict state machine, rerere integration, and sequencer semantics are
   git's, tested by git. **Rejected absent a demonstrated need**; the revisit trigger below defines
   what a demonstration would have to look like.

The chosen pipeline's costs are the other side of the comparison: far less code, git's own conflict
semantics reused rather than reimplemented, structured errors instead of sequencer state, and
intermediate objects in the ODB before the ref ever moves.

## Measured ground

Probes run 2026-09-09 in throwaway fixture repositories under `build/` inside the worktree
(`git version 2.50.1 (Apple Git-155)`). Both claims the decision leans on were measured before being
written.

### Probe 1 — `cherry-pick` conflict reporting is structured enough to drive the exit-8 contract

Single pick that conflicts (`topic change` onto `main change`, both editing `f.txt`):

```
$ git cherry-pick topic; echo "exit=$?"
Auto-merging f.txt
CONFLICT (content): Merge conflict in f.txt
error: could not apply 80d74b3... topic change
hint: After resolving the conflicts, mark them with
hint: "git add/rm <pathspec>", then run
hint: "git cherry-pick --continue".
...
exit=1
```

State left behind (all read back in the same fixture):

```
$ git status --porcelain
UU f.txt
$ git status --porcelain=v2 --branch
# branch.oid 6e2da11dcca6666045aeb26366e480d9c4e7cb6d
# branch.head main
u UU N... 100644 100644 100644 100644 df967b96... 6e68cef5... efb69661... f.txt
$ git ls-files -u
100644 df967b96... 1	f.txt
100644 6e68cef5... 2	f.txt
100644 efb69661... 3	f.txt
$ git diff --name-only --diff-filter=U
f.txt
$ ls .git | grep -Ei 'cherry|merge|sequencer'
AUTO_MERGE
CHERRY_PICK_HEAD
MERGE_MSG
$ git rev-parse -q --verify CHERRY_PICK_HEAD
80d74b3cab8a7407956ed9435eecc224c3f9635d
$ cat .git/MERGE_MSG
topic change

# Conflicts:
#	f.txt
```

Resumability, measured with a two-commit pick where the first conflicts:

```
$ git cherry-pick topic~1 topic; echo "exit=$?"
CONFLICT (content): Merge conflict in f.txt
error: could not apply 80d74b3... topic change
exit=1
$ ls .git/sequencer
abort-safety
head
todo
$ cat .git/sequencer/todo
pick 80d74b3 topic change
pick 7138d35 topic second
$ git cherry-pick --abort && git status --porcelain
(empty output — clean, verified)
```

Reading:

- **Detection** is unambiguous: exit 1, stderr `error: could not apply <sha> <subject>`, and
  `git rev-parse -q --verify CHERRY_PICK_HEAD` succeeds; conflicted paths come from
  `git diff --name-only --diff-filter=U` (or `ls-files -u` for stage detail).
- **State is typed by git itself**: `CHERRY_PICK_HEAD`, `MERGE_MSG` with a `# Conflicts:` path list,
  unmerged index stages 1/2/3, and — for multi-pick — `.git/sequencer/todo` naming the remaining
  picks. `AUTO_MERGE` also appears on this git version.
- **Resume and undo are owned by git**: `cherry-pick --continue` finishes the sequence, and
  `--abort` restored the fixture to a clean tree (empty porcelain, verified above).
- **Exit-8 mapping**: the contract's payload carries `{pick sha, conflicted paths, remaining todo}`;
  resume is the continued pick sequence; undo is `JournalCheckpoint.around` rollback, which covers
  the abort semantics without depending on sequencer files surviving.

### Probe 2 — `commit-tree` and signatures

Environment: no gpg on `PATH`, no `user.signingkey` configured — i.e. signing configured but a
signature cannot be produced. Findings, with the objects printed:

1. **`commit-tree` ignores `commit.gpgsign`.** With signing configured,
   `git -c commit.gpgsign=true commit-tree $tree -m ct-config-only` exited **0** and produced a
   **silently unsigned** commit:

   ```
   $ git -c commit.gpgsign=true commit-tree "$tree2" -m ct-config-only
   exit=0
   $ git cat-file commit <that sha>
   tree 3be22be77da4887e869c981806d8452f034dd014
   author Probe <probe@example.com> 1789010416 -0700
   committer Probe <probe@example.com> 1789010416 -0700

   ct-config-only
   ```

   No `gpgsig` header (a second run confirmed: `git cat-file commit <sha> | grep -c gpgsig` → `0`).
   On this path, signing configured-but-unproducible would be **invisible**.

2. **`commit-tree` can sign, but only with explicit `-S[<keyid>]`** (option present in 2.50.1). With
   no gpg available it fails loudly and writes nothing:

   ```
   $ git commit-tree -S -m ct-explicit-S "$tree2"
   error: cannot run gpg: No such file or directory
   error: gpg failed to sign the data:
   (no gpg output)
   exit=1
   ```

   Same for an unusable key (`-c user.signingkey=BBBB… commit-tree -S …` → exit 1, same errors).
   **A failed `-S` writes no object**: `git count-objects -v` counted 6 loose objects before and
   after the failed attempt — the failure is loud and clean.

3. Baseline for the same condition through porcelain:
   `git -c commit.gpgsign=true commit -m signed-porcelain` → exit **128**,
   `error: gpg failed to sign the data` + `fatal: failed to write commit object`.

### What this does to the signing story

The clean-room note said signed commits "stay signed naturally, since every rewritten commit is
created through the same path as an ordinary one". The measurement corrects the **mechanism**, not
the decision — the plan's "signed by construction" assumption was too optimistic about config:

- A rewritten commit can never carry the old signature across: the signature covers the original
  object's bytes; a rewrite produces different bytes and a different oid. Every descendant of a
  signed commit is either re-signed or unsigned, never "still signed".
- The pipeline therefore creates replacements through `CommitCreate`'s signing path and passes
  **`-S` explicitly** — never relying on `commit.gpgsign`, which `commit-tree` silently ignores
  (finding 1 above).
- If the source commit is signed and a replacement signature cannot be produced, the rewrite
  **fails loudly** (`commit-tree -S` exits 1 and writes no object — measured) and maps to the typed
  failure path; it never substitutes a silently unsigned replacement. Dropping the signature with a
  stated rule was considered and rejected: it would silently violate #0061/#0062/#0063's
  "signed commits stay signed" criterion. `git commit --amend`-style resigning was also rejected for
  rewrites: amend operates only on `HEAD` and disturbs worktree/index state mid-rewrite, which the
  `commit-tree` path avoids by construction.

## What the decision costs each command

- **`reword` / `drop` / `reorder`**: the descendant walk plus replay legs; conflicts surface only
  where the modified list actually conflicts, as exit-8 per the mapping above.
- **`split`**: two `commit-tree` calls plus index manipulation on stable hunk IDs (#0016); no replay
  beyond the split point's own descendants.
- **`absorb`**: `cherry-pick` replay of descendants — the one genuine replay consumer, and the
  exit-8 contract's main producer.
- **Signing** (all commands): explicit `-S` through `CommitCreate`'s signing path; loud failure when
  unproducible; old signatures never carried across.
- **Rerere risk (#0065)**: rerere may replay recorded resolutions differently from what
  `git rebase` would do — the standing risk the decision accepts.

## Revisit trigger

A **specific M5 command demonstrably failing under this pipeline** — a repro against the pipeline,
not an argument from capability. The concrete candidate already on record is **rerere replay
(#0065)** diverging from `git rebase` expectations. Until that reproduces, no additional machinery
is built.

## Files touched by this decision

- `docs/switchyard-development-guide.md` §11 — the question moved from still-open to settled,
  citing this doc.
- `docs/clean-room/rebase-engine-scope.md` — dated addendum appended, pointing here.
- Built on by #0061, #0062 and #0063, whose done-criteria inherit the signing rules above.
