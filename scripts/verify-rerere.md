# Manual rerere verification — the app surface (#0065 round 2)

The rerere sidebar section, its Detail pane, and the forget arm need a human
looking at a real repository in the running app, so they cannot be exercised
by `swift test`. The engine reads (`Rerere.status`, `Rerere.resolution(for:)`),
the mutation (`rerereForget`), the loaders, and the public view surfaces are
covered by the package suite (`YardKit/Tests/YardUITests/RerereSurfaceTests.swift`
and the round-1 engine tests). What this file owns is the end-to-end
behaviour in the app. It is the sibling of `scripts/verify-resolve.md` and
`scripts/verify-review.md`.

**The rule (same as `scripts/verify-resolve.md`):** an issue that claims
rerere verification without naming a scenario number from this file has not
verified anything. Cite the scenario number and its outcome ("scenario 1:
observed, the Rerere section listed f.txt and a 12-hex id", "scenario 4:
unrun on this machine because …"). Every scenario below is **UNRUN**:
written on the round that built the feature, which cannot launch or install
the app (signing rules). Expected output is a *shape* derived from the
source (`RepositorySidebarView.swift`, `RerereDetailView.swift`,
`ContentView.swift`, `RepositoryLoader.swift`, `RerereResolution.swift`,
`RerereForget.swift`), not an observation — when you run a scenario, paste
what you saw into it and flip the mark.

The recorded-diff bytes and the forget behaviour below are the ones measured
on git 2.50.1 during this round (fixture repositories under `build/`);
`git rerere diff` and friends print nothing once a conflict settles, which
is why the Detail pane shows the diff computed from the rr-cache bytes.

## How a human runs this

1. **Build and install the app** (see `scripts/verify-install.md`).

2. **Build the recorded-resolution fixture** with real git:

   ```sh
   git init rerere-app && cd rerere-app
   git config rerere.enabled true
   printf 'a\nb\nc\n' > f.txt && git add f.txt && git commit -m base
   git branch side
   printf 'a\nB\nc\n' > f.txt && git add f.txt && git commit -m ours
   git checkout side && printf 'a\nX\nc\n' > f.txt && git add f.txt \
     && git commit -m side
   git checkout - && git merge side      # CONFLICT (content): f.txt
   printf 'a\nR\nc\n' > f.txt && git add f.txt && git commit -m resolved
   ```

   The commit prints `Recorded resolution for 'f.txt'.` — after this, the
   rr-cache holds `preimage` (the conflict with markers) and `postimage`
   (the resolution), and every `git rerere` text surface prints nothing.

3. **Open the repository in the app** (File ▸ Open or drag-and-drop).

4. **Read the same state the app reads:**

   ```sh
   switchyard rerere status --json       # the round-1 arm: enabled + entries
   ```

## Scenario 1 — The sidebar shows the recorded resolution — UNRUN

**Preconditions.** App running; the fixture open in a tab.

**Expected** (observed by the human): the Sidebar pane gains a **Rerere**
section between Worktrees and Stashes (hidden entirely when nothing is
recorded — the same empty-section idiom as Branches/Remotes/Tags/Worktrees).
One row: `f.txt` with a merge glyph, and beneath it the first 12 characters
of the conflict id (monospaced, secondary — the same caption shape the
worktree rows use for a branch name). Cross-check the id:

```sh
switchyard rerere status --json        # "conflictID" begins with the same 12 hex characters
```

**Fail** when: the section is missing with a recorded resolution present,
the row shows a merely-known conflict (a live conflict git is tracking but
no resolution exists for yet), or the id does not match `rerere status`.

## Scenario 2 — Selecting the resolution shows its recorded diff — UNRUN

**Preconditions.** Scenario 1 observed.

**Expected** (observed by the human): clicking the row marks it semibold and
the Detail pane switches to the rerere view: the heading "Recorded rerere
resolution", the full conflict id beneath it (selectable, monospaced), then
the recorded diff rendered through the same hunk view the commit Detail
pane uses:

```
@@ -1,7 +1,3 @@
 a
-<<<<<<<
-B
-=======
-X
->>>>>>>
+R
 c
```

That is the preimage → postimage diff of the fixture: the conflict markers
and both sides removed, the resolution `R` added. **Fail** when: the pane
shows the commit view instead, the diff shows conflict-marker prose rather
than the hunk shape, or the body lines differ from what
`switchyard rerere status --json` round-trips.

## Scenario 3 — Replay is reported in command output, never silent — UNRUN

**Preconditions.** Scenario 1 observed; then re-raise the identical
conflict:

```sh
git reset -q --hard HEAD~1
git merge side                          # Resolved 'f.txt' using previous resolution.
```

**Expected** (observed by the human): the merge prints `Resolved 'f.txt'
using previous resolution.`, `f.txt` already holds `a\nR\nc\n` (no
markers), and the app-visible surfaces report the replay:

```sh
switchyard conflicts > conflicts.json
# expect the u record for f.txt to carry rerereReplayed: ["f.txt"]
cat f.txt                               # expect: a\nR\nc\n — replayed, not re-conflicted
```

The app's conflicts surface (round 1) reports `rerereReplayed`; the sidebar
row now shows the attributed path because the replay attributes it. **Fail**
when: the conflict replays with no `rerereReplayed` record anywhere (a
silent replay is the bug this issue exists to prevent), or `f.txt` shows
conflict markers instead of the resolution.

## Scenario 4 — Forget, behind its confirm step, removes the resolution — UNRUN

**Preconditions.** A replayed, still-live conflict from scenario 3 (the row
must have an attributed path — see the gate note below), or re-raise again
after re-resolving.

**Expected** (observed by the human): in the Detail pane, below the diff,
the **Forget…** button. Clicking it does NOT forget — it swaps to an orange
warning ("Forget this resolution? The same conflict will ask for a human
resolution again instead of replaying it.") with **Cancel** and a red
**Forget resolution** confirm (the review sheet's amend-confirm idiom).
Confirming runs `git rerere forget` and the pane reports "Resolution
forgotten." with git's own line; the sidebar reloads and the row leaves the
Rerere section (the entry is now merely known — preimage without a
postimage). Cross-check:

```sh
switchyard rerere status --json        # expect the entry's state to be "known", not "recorded"
```

Re-raise the conflict once more: the working file now shows conflict
markers again (no replay — the resolution is gone). **Fail** when: a single
click forgets without the confirm step, the row disappears while the entry
is still `"recorded"`, or the re-raised conflict replays the forgotten
resolution.

**Gate note (by design):** the Forget arm is offered only when a live path
is attributed to the entry. git identifies recorded resolutions by
conflicted path (measured: no `git rerere` subcommand takes a conflict id),
so a settled resolution — recorded, conflict long over, no live path —
shows "git identifies recorded resolutions by conflicted path, and no live
path is attributed to this one…" instead of the button. Forgetting such a
resolution from a terminal, while the conflict is live on another machine,
or after re-raising it, is the workaround until git grows an id-keyed
surface.

## Scenario 5 — A disabled or empty repository hides the section — UNRUN

**Preconditions.** App running; a repository with no rr-cache entries
(fresh clone, or rerere never enabled).

**Expected** (observed by the human): no Rerere section in the sidebar at
all — not an empty section, not a disabled note — matching the empty-section
idiom of the other sections. Cross-check:

```sh
switchyard rerere status --json        # expect enabled:false, entries:[]
```

**Fail** when: an empty "Rerere" heading renders, or a repository WITH
recorded resolutions hides the section.
