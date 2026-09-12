# Restore's primitive — whole snapshot or delta

**Prepared 2026-09-10 (issue #0258, round 1).** Milestone M5. Prepares guide §11's open question on
restore's primitive for a decision. **The recommendation below is a recommendation; the decision is
Brennan's** — guide §11's rule is that these are decided with Brennan, not in code, and this round
decided nothing in code.

Source of the question: [clean-room/snapshot-and-undo.md](clean-room/snapshot-and-undo.md)'s
addendum, written from GitUp's public headers only (GPLv3 — no implementation was read and nothing
here is derived from it). The addendum observed that GitUp's snapshot API has two shapes
Switchyard's has one: restore scoped by ref class, and a **delta operation** — "apply the
difference between snapshot A and snapshot B" — alongside "make the repository match snapshot B".
Four M2 issues (#0231, #0232, #0248, #0251) each patched one seam of *"apply this whole snapshot"*
being the primitive. This document measures whether the primitive underneath them should change.

## The question

Does `RefSnapshot` grow a delta application — `apply(from:to:)` — alongside `restore`, or stay
snapshot-only?

**The two primitives, stated precisely**, because the comparison below depends on the exact
definitions:

- **Whole-snapshot apply (today).** `RefSnapshot.restore` writes `update <name> <oid>` for **every
  ref the snapshot records** and touches nothing else (`RefSnapshot.swift:243-270`; deletion of
  unrecorded refs was removed by guide §11 decision 20, on #0231). `HEAD` is written
  unconditionally, first and alone, with `option no-deref`. Every recorded ref gets a command even
  when the live value already equals the recorded one — a no-op write is still a write.
- **Delta apply.** `apply(from:to:)` writes the **key set**: every ref name where `from` and `to`
  disagree, at `to`'s value — plus `HEAD` when the two heads disagree, same two-transaction
  mechanics. Everything else is untouched, by construction.
  **The deleting variant is not on the table**: a name `from` records and `to` does not would
  command a deletion, and applying it would re-create the exact failure decision 20 fixed
  (#0231) — a ref whose absence is "part of the delta" but whose current holder is a sibling's
  work would be destroyed. GitUp can run a deleting delta because one process owns the repository;
  Switchyard's premise is that it never does. So the only defensible delta is the **non-deleting**
  one, whose key set is: *names `to` records at a value `from` does not*.

## Measured ground — what a journal entry already stores

Checked against a real journal entry, not from the source alone: a `FixtureRepository`-created
fixture, two entries written by the real `JournalCheckpoint.checkpoint`, then the anchor commits
read back with `git ls-tree` and `git cat-file` (probe under `build/journal-probe/`, not committed).

Each entry's anchor commit stores a tree of: `metadata.json`, **`refs`** (one blob), optional
`index`/`index.raw`/`untracked`/`sequencer` trees and a `worktree-commit` gitlink
(`JournalAnchor.swift:148-169`). The `refs` blob is the **complete** snapshot, in the pinned line
format (`RefSnapshotSerialization.swift:20-26`):

```
switchyard-refs 1
head symbolic refs/heads/main
6002e8cd865a7af79469220a88fd7d859c2b3696 refs/heads/main
6002e8cd865a7af79469220a88fd7d859c2b3696 refs/remotes/origin/main
6002e8cd865a7af79469220a88fd7d859c2b3696 refs/tags/v1
```

**Verdict: a delta between two recorded snapshots is computable from what the journal already
stores, with zero new storage and no format change.** Decode both entries' `refs` blobs with the
existing `RefSnapshot(serialized:)`, diff by name. The probe did exactly that against two real
entries and computed, from the stored bytes alone: `added: [refs/heads/feature]`, head
`refs/heads/main → refs/heads/feature`, everything else untouched. The format is wire contract
("may only change behind a new version number") — **unchanged**, because the delta is computed at
apply time from two existing blobs rather than stored.

Both endpoints of every journal move are already recorded entries: a traversal step's `from` is the
scoped chain cursor's snapshot (`JournalRestore` step 4 reads that blob today), its `to` is the
target entry's; an explicit restore's `from` is the cursor or a fresh capture, which step 7's
pre-restore entry then records. Nothing needs to start being captured. `JournalRebuild` (#0030),
which recovers the journal from refs alone treating each blob as a complete snapshot, is unaffected.

One honest scope note: the delta is a **refs + HEAD** concept. The index, worktree, untracked and
sequencer pieces (`IndexSnapshot`, `WorktreeSnapshot`, `SequencerSnapshot`) have no delta notion
and would keep applying whole — which is also the only territory the four seams lived in.

## The four seams, primitive by primitive

What each fix **actually does** today, and what the non-deleting delta changes:

| seam | what its fix does | under a delta |
|---|---|---|
| #0231 | restore stopped deleting unrecorded refs (decision 20) — `update`-only over recorded refs | incident shape dissolves; the non-deletion choice **transfers** into the key-set definition |
| #0232 | three-snapshot `diff(recorded:applied:current:)` threaded through step 4; refuse only on a third value over names `applied` records | the "what will this restore write" question **is** the delta's key set — the threading dissolves; the third-value refusal **survives unchanged** on the key set |
| #0248 | skip became `if target == nil { continue }`; two tests re-keyed onto third-value shapes | a name **neither** side records is outside any key set — genuinely no rule; the believed-only half is absorbed into the key-set definition |
| #0251 | live-held branches dropped from `toApply` **after** the guard; `Report.leftAlone` names them (decision 23); prunable holders restored | **survives unchanged** — the check is about worktree checkouts, not ref-set width; narrower input, same rule, same drop-after-guard order |

Details, with the rule citations checked against the code:

- **#0231 — the non-deletion rule survives; it becomes the delta's definition.** The probe's
  incident (a branch in neither snapshot, deleted by restore) cannot recur under either variant.
  But the *choice* decision 20 made does not dissolve — it reappears as the line defining the key
  set. A delta with a deletion arm is strictly **more** dangerous than today's fixed restore: for
  a ref `from` records, `to` doesn't, and a sibling re-created since, today's restore leaves it
  (unrecorded by `applied`); a deleting delta removes it. Adopting the delta therefore means
  re-making decision 20 inside the primitive, not retiring it.
- **#0232 — the plumbing dissolves, the rule survives.** What round 2 actually landed
  (`CrossToolGuard.swift:148-174`, threaded through `JournalRestore` step 4 at
  `JournalRestore.swift:334-359`) is: skip any name `applied` does not record; for the rest,
  refuse only when `current` matches **neither** `recorded` **nor** `applied`; `HEAD` always
  against `recorded`. Under a delta, "what this restore writes" needs no third snapshot — it is
  the key set. But every name *in* the key set is about to be overwritten with `to`'s value, so a
  foreign move to a third value must still refuse, exactly as today: the discriminator is the
  safety content of #0232 and it does not dissolve. What genuinely changes: names `applied`
  records but the traversal is **not** carrying (`from` == `to`, a no-op write today) generate no
  command under a delta and leave the guard's scope — today's restore writes them back, so the
  guard must check them, and a foreign move there refuses the whole restore
  (`anotherToolsMoveRefusesRestoreWhileTheChainStandsOnAnEntry` pins that refusal as *wanted*
  behavior today). A delta converts that refusal into a silent pass with the live value preserved;
  the pinned test would have to be re-decided, not just re-pointed.
- **#0248 — the one genuine dissolve.** A pure creation by another tool (its `worktree add -b`, its
  `git branch`) is a name neither snapshot records, which is outside the key set under **either**
  variant — no skip rule, no re-keyed tests. The skip's other half (a name `recorded` knows and
  `applied` does not) is the deletion question again: the non-deleting key set already excludes it,
  which is the same choice absorbed inward rather than retired.
- **#0251 — survives in full.** A live sibling's held branch is perfectly capable of being in a
  delta's key set (both endpoints routinely record it, at different values — that is what a
  traversal *is*). `WorktreeDisturbance.disturbances` + `leavingLiveDisturbances`, decision 23,
  `Report.leftAlone`, the drop-after-guard ordering that keeps a foreign move on a dropped branch
  visible, `detachingHeldHead` (#0211, decision 16) — none of it narrows. The check's input
  shrinks from the applied snapshot to the key set; the rule is identical.

So the addendum's "under a delta primitive, none of those questions arise" holds **only for the
guard-scope plumbing and the unrecorded-name cases**. The disturbance half — arguably the worst of
the four — is untouched, and the non-deletion half is re-decided, not dissolved.

## Migration and compatibility cost

- **Storage: none.** Entries already store complete snapshots; the delta is computed from two
  existing blobs; the `switchyard-refs 1` format is unchanged; no version bump; no backfill;
  #0030's rebuild unaffected.
- **Code: one additive API plus re-plumbing.** `RefSnapshot.apply(from:to:)` alongside `restore`;
  `JournalRestore` step 4's guard call would take the key set instead of `applied`; step 8 calls
  the delta for traversal steps. Whole-snapshot `restore` stays for explicit restore — the repo
  must still *match* a checkpoint on demand.
- **Test surface: the real cost.** Every rule above that survives must be pinned on the delta path
  too — the guard's third-value rule, the disturbance check, the head-detach, the drop-after-guard
  order — and the pinned no-op-write refusal must be re-decided before it can be re-pointed. This
  is the most safety-critical flow in the codebase (it is the one whose failure mode is silent
  data loss), so the delta roughly doubles the application surface that mutations must cover.

## Recommendation

**Recommendation for Brennan: stay snapshot-only.** Of the three rules a delta was expected to
dissolve, only #0248's skip genuinely does; #0232's third-value discriminator and #0251's entire
leave-alone machinery survive unchanged; and #0231's non-deletion becomes the delta's own defining
constraint — by the issue's own bar ("a change that keeps all three has not bought anything"), the
delta keeps about two and a half of three. What it would actually buy is one behavioral change —
the guard no longer refuses over a foreign move on a name the traversal is not carrying — and that
is a *narrower* refusal surface, not a simpler rule set, bought at the price of a second
application path through the restore flow and a doubled mutation surface. The four landed fixes
are correct, pinned by named tests with recorded mutations, and staying; the rebase-engine decision
(#0060) just chose the same shape for the adjacent question — no new machinery without a
demonstrated need.

**Reversal trigger** (either one, checked against the tracker not against memory):

1. **A fifth instance of the seam** that decisions 20 and 23 plus the three-snapshot guard cannot
   cover — i.e. a filed issue whose fix would be another scope rule or another skip clause, rather
   than a data point under an existing rule.
2. **The no-op-write refusal class showing up in ordinary two-agent use** — traversal steps
   repeatedly refused because another tool moved a ref the traversal is not carrying, with fresh-
   checkpoint recovery becoming a real operational cost rather than a theoretical one.

Either trigger fires: grow `apply(from:to:)` **additively**, non-deleting, traversal-only, with
whole-snapshot `restore` retained and every surviving rule re-pinned on the delta path — cheapest
to absorb inside the M5 rewrite-pipeline work, next to the primitive decision #0060 already
recorded there. Absent a trigger, this is settled as *answered, no* — the guide entry below says
so, so the fifth instance's finder starts from the reasoning rather than rediscovering it.

The decision is Brennan's; this document only prepares it.

---

## Decision — 2026-09-09, Brennan: stay snapshot-only

The recommendation is accepted as the decision. `RefSnapshot` stays whole-snapshot-only. A delta
application may be grown **additively** only on the named reversal trigger — a fifth seam instance
needing a new scope rule, or the no-op-write refusal becoming a real two-agent cost — and any such
delta is non-deleting and traversal-only, with #0231's non-deletion as its defining constraint.
#0258 closes with this decision; no code changes.
