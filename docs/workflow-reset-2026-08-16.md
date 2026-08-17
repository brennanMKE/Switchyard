# The 2026-08-16 workflow reset

`main` was reset to **`3c49ba6`** — *"#0035 resolved; baseline 831 -> 836; file the sequencer
wiring gap"*, 2026-08-09 19:08 — and force-pushed. Everything that had been committed after it is
preserved on branches; nothing was discarded. This file records what happened, where the work went,
and what has to be re-done.

## What went wrong

Between 2026-08-11 23:49 and 2026-08-13 01:53, seventeen commits landed on `main` outside the
workflow. Not one came from an issue branch or a reviewed round:

- **Twelve `#0153` commits** were hand-made off a working tree — `Add new source files from working
  tree`, `Add new test files from working tree`. That is how `HookStatus.swift`,
  `HookUninstall.swift`, `Unstaging.swift`, `JournalObserved.swift` and their tests reached `main`,
  carrying the work of #0158, #0159, #0161 and #0162 with them under a #0153 label.
- **A round was run in the primary checkout**, which the checkout rule exists to forbid. Its first
  attempt failed to compile; the record survives as
  `.switchyard-runs/0189-round1.failure.md`, and it was misnumbered — it was implementing **#0188**,
  and no `issues/0189.md` has ever existed. The failure was never entered in
  `docs/review-failures.md`, so the preflight never learned from it.
- **Four issues carried an illegal status** — `implemented (in working tree)`, which
  `scripts/set-issue-status.sh` does not accept and which was therefore hand-written into the files.
  It described a state the tracker has no room for: code that exists but is on no branch.

The result was a `main` whose history could not be read back to any issue, and 862 passing tests
that no review had ever seen.

## Where the work went

| Branch | Holds |
|---|---|
| `salvage/main-off-workflow` | The old `main` tip, `9c4b989`. All seventeen off-workflow commits, complete. |
| `salvage/0188-sequencer-wiring` | The #0188 sequencer wiring, which existed only as uncommitted working-tree changes in the primary checkout — on no branch anywhere. Verified green before salvage: 836 → 862 tests. |
| `issue/0124` | The #0124 round's uncommitted worktree state, committed before its worktree was removed. |

Both salvage branches are pushed to `origin`. The 129 pre-existing issue branches were pushed too —
ten of them had never left this machine — and then all 121 issue worktrees were removed, which
returned 22.2 GB. Removing a worktree does not delete its branch, so the record every issue's
`**Commit**` row points into is intact.

Round logs from the removed worktrees — 466 files — are archived at
`.switchyard-runs/archive/round-logs-20260816.tgz`.

## Verified state at the reset point

`swift build` clean, `swift test` **836 tests in 64 suites passing** — exactly the baseline
`3c49ba6` records in `docs/test-baseline.txt`. The reset landed on a genuinely good commit rather
than a plausible one.

## What has to be re-done

The code on `salvage/main-off-workflow` is not reachable from `main` and must not be merged
wholesale — merging it back is the same mistake a second time. Each of these goes through the
normal loop, and the salvage branch is a **reference for the planner**, not a shortcut for the
implementer:

- **#0153** — observed reference transactions (`JournalObserved.swift`).
- **#0158** — hooks uninstall with restore. **#0159** — hooks status reporting.
- **#0161** — HunkParser conflict-format lines. **#0162** — `unstageHunks` by hunk id.
- **#0188** — sequencer wiring, whose implementation is already written and green on
  `salvage/0188-sequencer-wiring`. It still needs the round-trip coverage its mutation rows ask for,
  and a review.
- **#0178** was set back to `open`; the commit that closed it is on the salvage branch, its work on
  `issue/0178`.

Three small changes on the salvage branch are unrelated to any issue and may be worth cherry-picking
on their own: `c519014` (`build.sh` for xcodebuild runs), `3a2e2dd` (Xcode project updated for
`YardUI`), and `82c3c15`'s documentation half.

**#0166 carries a known defect.** Its implementation (`0173f4c`) predates the reset and is still on
`main`, but the fix to its JSON key pinning and its chain test (`aef78c5`) is now only on
`salvage/main-off-workflow`.
