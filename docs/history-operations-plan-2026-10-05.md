# History operations: merge bug, Fixup with Parent, and real test automation

**Opened 2026-10-05**, from Brennan's manual test:

> I create a docs2 branch and added a file. Then changed back to main and used Merge Into Current
> Branch on the commit on the docs2 branch. It created a new commit on the main branch but no file
> change. Clearly that is a serious bug. … Also Fixup with Parent is disabled. I want this
> implemented. This is a great feature in GitUp which is the primary reference project. … Make sure
> the UI test automation is comprehensive.

## Why this got through

Every commit-menu operation has unit tests in YardGit, and none has a VM UI test. The only
history-related spike is #0430 (merged-lane dimming). The engine tests exercise `Merge.run` and the
rewrite engine directly; nothing drives **the app's** path — the commit menu, `CommitActionRequest`,
`CommitActionRunner`, the journal checkpoint around it, and the refresh — and then checks what git
actually holds afterwards. A merge commit "with no file change" is exactly the class of defect only
that end-to-end path can show. So the fix is not only the bug: it is a VM suite that asserts **git
state**, not just labels on screen.

## Workstreams

### A. The merge bug (serious; first)

1. **Reproduce in the VM**, never on the host, on a fixture built with git commands: `main`,
   `docs2` branched from it with one commit adding a file, back on `main`, Merge into Current Branch
   on `docs2`'s commit from the History menu. Assert with git, not the UI: after the merge, `HEAD`
   is a merge commit whose second parent is `docs2`'s tip, and `git ls-tree HEAD` contains the new
   file, and the working tree has it.
2. **Find the root cause** (candidates to rule in or out by measurement, not guess: the journal
   checkpoint restoring the worktree/index after the merge; the runner passing the selected commit's
   *parent* or `HEAD` instead of the branch; `--no-ff` against an already-merged ref; the merge
   running in the wrong worktree; a refresh showing stale state while git is right).
3. **Fix** with a unit test or engine test that fails before and passes after, plus the VM spike.
4. **Log it** in `docs/review-failures.md`: class, root cause, and the preflight check that would
   have caught it ("a commit-menu action ships with a VM spike that asserts git state").

### B. Fixup with Parent, GitUp-style (feature)

Today it is enabled only on the branch tip (`rewriteReason`: "Only the newest commit … can be
folded into its parent"), which is why Brennan sees it disabled.

- **Semantics, measured from Brennan's alias** (`~/.gitconfig`):
  `fixup = !git reset --soft HEAD~1 && git commit --amend --no-edit` — the selected commit's
  changes fold into its parent, **the parent's message is kept**, the selected commit's message is
  dropped. Squash with Parent already exists and combines messages; Fixup must not.
- **Scope:** any non-root, non-merge commit in the current branch's own history, not only the tip —
  the descendants are replayed on top, as Edit Message / Swap already do through the rewrite engine.
  GitUp is the behavioural reference: read it (GPL — understand, never copy or port) to confirm
  edge cases (selected commit is the tip; parent is the root; a descendant conflicts; a merge above).
- **Undo:** one journal entry; Edit ▸ Undo Fixup restores the branch exactly.
- **CLI:** check whether `switchyard` has a `fixup` verb; if not, record it as a question.
- Record the design as the next guide §11 decision.

### C. Comprehensive history-operation VM suite (the gap)

- **One fixture script built with git commands** (`scripts/uitest-fixtures/make-history-ops-fixture.sh`):
  `main` plus several branches shaped for every operation — fast-forwardable, diverged (true
  merge), conflicting (merge and rebase), a branch for rebase-onto, commits to cherry-pick and
  revert, a stack of small commits for fixup/squash/swap/delete/split/edit message, a tag. Deterministic
  dates and authors. Documented shape at the top of the script.
- **A git-state assertion helper for UI tests**, so each spike checks the repository itself:
  `git rev-parse`, `git log --format`, `git ls-tree`, `git diff --quiet`, parents of `HEAD`,
  the message, file contents. Decide (and measure) whether the XCUITest runner in the guest can run
  `/usr/bin/git` via `Process` against the fixture path; if not, find the reliable alternative.
- **One spike per operation**, each: perform it from the app's own UI (commit menu / context menu /
  shortcut), assert git state, then Edit ▸ Undo and assert the pre-state is back byte-for-byte:
  merge (fast-forward, true merge, conflict → resolve or abort), rebase onto (clean and conflicting),
  cherry-pick, revert, squash with parent, fixup with parent (tip and mid-branch, after B), swap
  with parent/child, delete commit, edit message, split, set branch tip, create branch / tag here.
- Must be runnable as one label and as part of the full pass, with screenshots kept.
- This is the template every future commit-menu action follows: no history operation lands without
  a spike that asserts git state.

## Order and ownership

1. **Plan (Opus, in parallel):** A, B and C each get a planner that reproduces or prototypes in its
   own worktree and the VM, and writes issues down to the code. C owns the fixture and the assertion
   helper; A and B write their spikes against C's helper (A may ship a minimal fixture first if C
   is not ready, then migrate).
2. **Build (Sonnet), review (Opus), merge** through the normal loop: worktree per issue, suite twice,
   a mutation, the issue's VM spikes, the full VM pass before closing each umbrella.
3. **A's fix ships first.** Then C's harness, then B on top of it, then the rest of C's spikes.

## Rules that apply throughout

- All UI testing in the VM (`scripts/run-ui-tests-vm.sh`); never on the host.
- GitUp is GPLv3: read to understand behaviour, write the idea down in our own words, never copy or
  translate code. GitHub may be consulted for git and GitUp behaviour notes.
- Tests assert git state and never wall-clock time; no network (local bare repos only).

## Status

| Workstream | Umbrella | State |
|---|---|---|
| A. Merge bug | #0575 (children #0576-#0579) | planned — git was right; the Detail pane hid every merge's files (`--cc` is empty for a clean merge). Dispatch #0576 → #0577 → #0578; #0579 any time after #0578 |
| B. Fixup with Parent | #0580 (children #0581-#0584) | planned — decision 46: any non-root, non-merge commit folds into its parent (parent's message and author kept), descendants copied by tree; prototype green and VM spike fails on main / passes with the change. Dispatch #0581 → #0582; #0583, #0584 after #0581 |
| C. History-operation VM suite | — | planning |
