# Manual resolve verification — `switchyard resolve --wait` (#0057)

The resolve round-trip needs a human looking at a real resolution pane in the
running app, so it cannot be exercised by `swift test`. The blocking
semantics, the wire types, the pending store, the engine apply half, the
pane's model, and the arm's exit mapping are covered by the package suite
(`YardKit/Tests/`); what this file owns is the end-to-end behaviour with a
real installed app. It is the sibling of `scripts/verify-review.md` and
`scripts/verify-ask.md`.

**The rule (same as `scripts/verify-review.md`):** an issue that claims
resolve verification without naming a scenario number from this file has not
verified anything. Cite the scenario number and its outcome ("scenario 2:
observed, exit 0 and the envelope carried the useOurs resolution",
"scenario 7: unrun on this machine because …"). Every scenario below is
**UNRUN**: written on the round that built the feature, which cannot launch
or install the app (signing rules). Expected output is a *shape* derived
from the source (`ResolveArm.swift`, `ResolveRequestServing.swift`,
`ResolvePaneBridge.swift`, `ResolvePane.swift`), not an observation — when
you run a scenario, paste what you saw into it and flip the mark.

## How a human runs this

1. **Build and install the app** (the CLI ships inside the app bundle and is
   linked at `/usr/local/bin/switchyard`; see `scripts/verify-install.md`).
   `switchyard resolve` never launches the app — it must already be running,
   or the scenario expects exit 3.
2. **A resolve blocks**, so run it in the background with its stdout
   captured, resolve in the app, then read the file and the status:

   ```sh
   switchyard resolve --wait --timeout 300 > resolve-out.json &
   resolvePid=$!
   # … compose choices, press Stage resolution per card, then Submit …
   wait $resolvePid; echo "exit=$?"
   cat resolve-out.json
   ```

3. **The four conflict fixtures.** Each scenario names one; build it with
   real git (the shapes #0057 round 1 measured — no fixture helper needed):

   Content (`UU`):

   ```sh
   git init resolve-uu && cd resolve-uu
   printf 'base\n' > a.txt && git add a.txt && git commit -m base
   git branch theirs
   printf 'ours\n' > a.txt && git commit -am ours
   git checkout theirs && printf 'theirs\n' > a.txt && git commit -am theirs
   git checkout - && git merge theirs          # CONFLICT (content): a.txt
   ```

   Add/add (`AA`) — the path is NEW on both sides:

   ```sh
   git init resolve-aa && cd resolve-aa
   printf 'seed\n' > seed.txt && git add seed.txt && git commit -m seed
   git branch theirs
   printf 'ours\n' > new.txt && git add new.txt && git commit -m ours
   git checkout theirs && printf 'theirs\n' > new.txt
   git add new.txt && git commit -m theirs
   git checkout - && git merge theirs          # CONFLICT (add/add): new.txt
   ```

   Delete/modify (`DU`) — ours deleted, theirs modified:

   ```sh
   git init resolve-du && cd resolve-du
   printf 'base\n' > c.txt && git add c.txt && git commit -m base
   git branch theirs
   git rm c.txt && git commit -m 'delete c'
   git checkout theirs && printf 'modified\n' > c.txt && git commit -am modify
   git checkout - && git merge theirs          # CONFLICT (modify/delete): c.txt
   ```

   Rename/rename(1to2) — both sides renamed the same file differently; this
   surfaces as THREE records: `DD` at the old path, `AU` at ours' new path,
   `UA` at theirs' new path:

   ```sh
   git init resolve-rr && cd resolve-rr
   printf 'content\n' > d.txt && git add d.txt && git commit -m base
   git branch theirs
   git mv d.txt ours-name.txt && git commit -m 'ours renames'
   git checkout theirs && git mv d.txt theirs-name.txt
   git commit -m 'theirs renames'
   git checkout - && git merge theirs          # CONFLICT (rename/rename)
   ```

4. **Read the same records the pane does:**

   ```sh
   switchyard conflicts                        # the u records: path, kind, stages
   git status --porcelain=v2 | grep '^u '      # the same records raw
   ```

   `switchyard conflicts` is also the after-state check: every scenario's
   "conflicts unchanged" and "all resolved" claims read its result array.

## Exit codes

Every number below is a case of `ExitCode` (`YardKit/Sources/YardKit/ExitCode.swift`) —
cited by case name, never from memory. The JSON envelope carries the same
code as its `error.code` string (`ExitCode.codeLabel`), so stdout and the
process exit status always agree.

| Exit | Case | `error.code` | Meaning |
|---|---|---|---|
| 0 | `.success` | `ok` | Every conflicted path resolved after the reply |
| 1 | `.usage` | `usage` | Bad arguments (e.g. missing `--wait`) |
| 2 | `.brokerUnreachable` | `broker_unreachable` | Broker Mach service unreachable |
| 3 | `.appUnavailable` | `app_unavailable` | App not running and never launched |
| 4 | `.requestFailed` | `request_failed` | Superseded, or the app could not serve |
| 5 | `.sessionTerminated` | `session_terminated` | App quit mid-resolve — never a decision |
| 6 | `.repositoryError` | `repository_error` | Working directory is not a repository |
| 7 | `.humanDeclined` | `human_declined` | Cancelled (envelope is still `"ok":true`) |
| 8 | `.blockedOnConflicts` | `blocked_on_conflicts` | Conflicts remain after the reply (envelope is still `"ok":true`) |
| 10 | `.timedOut` | `timed_out` | No reply within `--timeout` |

Success envelope: `{"ok":true,"result":{…},"schemaVersion":1}` with the
result being the reply: `{"resolutions":[…]}` — one `PathResolution` per
card (`path`, `kind` as the porcelain pair, `choice`, `editedContent` only
when edited, `note` only when written) — or `{"cancelled":true}`. Failure
envelope: `{"error":{"code":"…","message":"…"},"ok":false,"schemaVersion":1}`
with the human-readable duplicate `[error] <code>: <message>` on stderr.
Keys are sorted; no trailing newline.

---

## Scenario 1 — A content conflict resolved end to end: exit 0 with the structured resolutions — UNRUN

**Preconditions.** App running; the content fixture (resolve-uu); the
repository already open in a tab (the no-tab case is scenario 10).

```sh
cd /path/to/resolve-uu
switchyard resolve --wait --timeout 300 > resolve-out.json &
resolvePid=$!
```

The app routes the resolve to the repository's tab (#0084) and the Detail
pane presents "Resolve conflicts — 1 conflicted path": one card at `a.txt`
labelled "Content conflict", the sides Ours / Base / Theirs rendered side by
side with the conflict markers visible verbatim. Choose **Use ours** (the
pre-composed default), type `keep our wording` in the note field, press
**Stage resolution** — the card gains the Staged badge — then press
**Submit resolutions**.

```sh
wait $resolvePid; echo $?                    # expect: 0
cat resolve-out.json
switchyard conflicts                         # expect: "result":[]
cat a.txt                                    # expect: ours
```

**Expected** (shape): exit **0** (`.success`) and

```json
{"ok":true,"result":{"resolutions":[{"choice":"useOurs","kind":"UU","note":"keep our wording","path":"a.txt"}]},"schemaVersion":1}
```

`git status --porcelain=v2` shows no `u` records; `a.txt` holds ours' text;
the index matches (`git diff --cached` shows ours' content against HEAD).
**Variant (the editor):** choose **Edit merged** instead — the editor is
seeded with the working file's conflict-marked text; save exactly
`merged\n`, stage, submit. The record is then
`{"choice":"editedContent","editedContent":"merged\n","kind":"UU","path":"a.txt"}`
— what you saved is what staged. **Fail** when: the exit differs, the record
carries a `note` or `editedContent` you did not type, or the working file
does not hold the chosen content.

---

## Scenario 2 — An add/add conflict: exit 0, no base side — UNRUN

**Preconditions.** App running; the add/add fixture (resolve-aa).

```sh
cd /path/to/resolve-aa
switchyard resolve --wait --timeout 300 > resolve-out.json &
resolvePid=$!
# the card is labelled "Add/add conflict" at new.txt and shows only Ours
# and Theirs — add/add has no base stage; the editor is seeded with ours
# (pick "Use theirs", stage, submit)
wait $resolvePid; echo $?                    # expect: 0
cat resolve-out.json
cat new.txt                                  # expect: theirs
```

**Expected** (shape): exit **0** with

```json
{"ok":true,"result":{"resolutions":[{"choice":"useTheirs","kind":"AA","path":"new.txt"}]},"schemaVersion":1}
```

and `switchyard conflicts` reporting an empty result. **Fail** when the
card rendered a Base column (there is no stage 1 for an add/add conflict)
or the staged file holds anything but theirs' text.

---

## Scenario 3 — A delete/modify conflict, by pathspec: exit 0 — UNRUN

**Preconditions.** App running; the delete/modify fixture (resolve-du).
The pathspec form is exercised here: one path, exact match.

```sh
cd /path/to/resolve-du
switchyard resolve c.txt --wait --timeout 300 > resolve-out.json &
resolvePid=$!
```

**Expected** (observed by the human): the pane's card is `c.txt` only —
"Delete/modify conflict", the choices **Keep the deletion** (pre-composed) /
**Keep the modification** / **Edit merged**, the editor (on Edit merged)
seeded with the surviving side. Choose **Keep the modification**, stage,
submit.

```sh
wait $resolvePid; echo $?                    # expect: 0
cat resolve-out.json                         # {"ok":true,"result":{"resolutions":[{"choice":"keepModification","kind":"DU","path":"c.txt"}]},…}
git status --porcelain=v2                    # no u records
cat c.txt                                    # expect: modified
```

**Fail** when: the pane offered paths outside the pathspec's scope, the
exit differs, or the working file was overwritten with something other than
the surviving side's blob.

---

## Scenario 4 — A rename group end to end: three records, exit 0 — UNRUN

**Preconditions.** App running; the rename/rename fixture (resolve-rr).
The pane shows three cards: `d.txt` "Both-deleted conflict" (explanation +
**Keep the deletion**), `ours-name.txt` "Rename conflict" (**Take ours'
path+content** / **Keep the deletion**), `theirs-name.txt` "Rename
conflict" (**Take theirs' path+content** / **Keep the deletion**).

**Expected** (observed by the human): take ours' rename on the AU card
(default), pick **Keep the deletion** on the UA card (dropping theirs'
rename) and on the DD card; stage all three; submit.

```sh
cd /path/to/resolve-rr
switchyard resolve --wait --timeout 300 > resolve-out.json &
resolvePid=$!
# … AU card: keep "Take ours' path+content"; Stage
# … UA card: pick "Keep the deletion"; Stage
# … DD card: keep "Keep the deletion"; Stage
# … Submit resolutions
wait $resolvePid; echo $?                    # expect: 0
cat resolve-out.json
```

**Expected** (shape): exit **0** with three records —

```json
{"ok":true,"result":{"resolutions":[{"choice":"keepDeletion","kind":"DD","path":"d.txt"},{"choice":"keepDeletion","kind":"UA","path":"theirs-name.txt"},{"choice":"renameTakeOurs","kind":"AU","path":"ours-name.txt"}]},"schemaVersion":1}
```

and the working tree: `ours-name.txt` holds ours' content and is staged,
`theirs-name.txt` is gone, `d.txt` is gone, `switchyard conflicts` prints an
empty result. **Fail** when: the DD card presents read-only with no stage
button (a both-deleted record must be stageable — it is the group's old
path), the old path's unmerged entries survive the submit (that forces exit
8 forever), or the exit differs.

---

## Scenario 5 — Cancel stages nothing: exit 7, conflictedFiles unchanged — UNRUN

**Preconditions.** App running; the content fixture (resolve-uu); capture
the before-state first.

```sh
cd /path/to/resolve-uu
switchyard conflicts > conflicts-before.json
git status --porcelain=v2 > status-before.txt
switchyard resolve --wait --timeout 300 > resolve-out.json &
resolvePid=$!
# … press Cancel — stage nothing —
wait $resolvePid; echo $?                    # expect: 7
cat resolve-out.json
switchyard conflicts > conflicts-after.json
git status --porcelain=v2 > status-after.txt
diff conflicts-before.json conflicts-after.json   # expect: no output
diff status-before.txt status-after.txt           # expect: no output
```

**Expected** (shape): exit **7** (`.humanDeclined`) with stderr
`[error] human_declined: the resolve was cancelled; nothing was staged` and
the envelope still `"ok":true` — the JSON is the contract, the exit code is
the signal:

```json
{"ok":true,"result":{"cancelled":true},"schemaVersion":1}
```

The index, the conflicted records, and the working file (conflict markers
included) are byte-identical to the before-state — cancelling stages
nothing, touches nothing. **Fail** when: the envelope is `"ok":false`, the
exit is anything but 7, or any file/index record moved.

---

## Scenario 6 — Conflicts remain on return: exit 8, envelope still ok:true — UNRUN

**Preconditions.** App running; a repository with TWO content conflicts:

```sh
cd /path/to/resolve-uu
printf 'base2\n' > b.txt && git add b.txt && git commit -m base2
git branch theirs2
printf 'ours2\n' > b.txt && git commit -am ours2
git checkout theirs && printf 'theirs2\n' > b.txt && git commit -am theirs2
git checkout - && git merge theirs           # a.txt and b.txt both UU
```

(Or rebuild the fixture with both files; either way `switchyard conflicts`
lists two paths.)

```sh
switchyard resolve --wait --timeout 300 > resolve-out.json &
resolvePid=$!
# … a.txt: Use ours, Stage; b.txt: stage NOTHING; Submit resolutions
wait $resolvePid; echo $?                    # expect: 8
cat resolve-out.json
switchyard conflicts                         # still lists b.txt
```

**Expected** (shape): exit **8** (`.blockedOnConflicts`) while the envelope
is still `"ok":true` carrying the reply — the reply is the record, the
re-check is the signal:

```json
{"ok":true,"result":{"resolutions":[{"choice":"useOurs","kind":"UU","path":"a.txt"},{"choice":"useOurs","kind":"UU","path":"b.txt"}]},"schemaVersion":1}
```

stderr: `[error] blocked_on_conflicts: 1 conflicted path(s) remain`. The
reply carries a record for every card — staged or not (the still-open card
composes its current selection); the conflicts re-check after the reply is
what decides the exit. **Fail** when: exit 0 while b.txt is still conflicted,
or the envelope turned `"ok":false` (conflicts remaining is a decision
outcome, not an error).

---

## Scenario 7 — Timeout: exit 10, the pane banners — UNRUN

**Preconditions.** App running; the content fixture (resolve-uu); the human
answers nothing.

```sh
cd /path/to/resolve-uu
switchyard resolve --wait --timeout 5
echo $?                                      # expect: 10
```

**Expected** (shape): after ~5 s (the store's own typed timeout, which beats
the CLI's `--timeout + 5 s` backstop), exit **10** (`.timedOut`) with

```json
{"error":{"code":"timed_out","message":"no resolve reply arrived in time"},"ok":false,"schemaVersion":1}
```

stderr: `[error] timed_out: no resolve reply arrived in time`. The pane
stays until the human closes its banner ("This resolve timed out before a
decision was made."), with its buttons disabled. **Fail** when: exit 2, a
hang past ~10 s, or a decision-shaped envelope. (If the CLI's backstop
fires first the message reads "no resolve reply arrived within 5s" — same
code, same exit; the store's typed timeout normally wins.)

---

## Scenario 8 — App not running: exit 3, never a fallback — UNRUN

**Preconditions.** The app is not running: `pgrep -x Switchyard` prints
nothing.

```sh
pgrep -x Switchyard                 # expect: no output
cd /path/to/resolve-uu
switchyard resolve --wait --timeout 300
echo $?                             # expect: 3
pgrep -x Switchyard                 # still no output — resolve never launches
```

**Expected** (shape): exit **3** (`.appUnavailable`), immediately, with

```json
{"error":{"code":"app_unavailable","message":"…"},"ok":false,"schemaVersion":1}
```

An agent proceeding without the human's resolutions would be a bug — there
is no non-interactive fallback. **Fail** when: the process hangs, a pid
appears, or the exit is anything but 3.

---

## Scenario 9 — App quits mid-resolve: exit 5, never a decision — UNRUN

**Preconditions.** App running; a resolve in flight (scenario 2's shape).

```sh
cd /path/to/resolve-uu
switchyard resolve --wait --timeout 300 > resolve-out.json &
resolvePid=$!
sleep 2
osascript -e 'quit app "Switchyard"'
wait $resolvePid; echo $?
cat resolve-out.json
```

**Expected** (shape): exit **5** (`.sessionTerminated`) with
`"code":"session_terminated"` — conflation with a cancellation (7) would be
the serious bug: an agent must never read a crash as a considered human
decision. **Fail** when: exit 7, a `resolutions`/`cancelled` payload, or a
hang.

---

## Scenario 10 — No tab for the repository: opened and focused (#0084) — UNRUN

**Preconditions.** App running with at least one repository open, and the
resolve fixture in a repository the app has no tab for.

```sh
cd /path/to/unopened/resolve-uu
switchyard resolve --wait --timeout 300 > resolve-out.json &
resolvePid=$!
```

**Expected** (observed by the human): a tab for the unopened repository
appears in the frontmost window, is selected, and the Detail pane presents
the resolution cards — no stray window, and the previously focused tab is
untouched. Resolve and submit; `wait $resolvePid` exits **0**. **Fail**
when: a new window opens, the wrong tab is focused, or the cards appear on
the wrong repository's tab.

---

## Not scenarios here, and why

- **Usage refusals (exit 1)** — `resolve` without `--wait`, two pathspecs,
  an empty pathspec, `--timeout abc`, an unknown flag: pure argv parsing,
  fully covered by `ResolveArmTests` (`nonWaitFormIsRefusedAsUsage` and
  neighbours); nothing app-side to observe.
- **Superseded (exit 4)** — a second `resolve --wait` for the SAME
  repository supersedes the first (review semantics, not ask's queue):
  covered by `PendingResolveStoreTests` and
  `ResolveArmTests/supersededOutcomeIsRequestFailedAndNeverADecision`; the
  manual form would only re-prove the store with a second terminal.
- **Non-repository working directory (exit 6)** — covered end-to-end shape
  by `ResolveArmTests/unresolvableRepositoryYieldsTheRepositoryErrorEnvelope`;
  nothing registers and the failure envelope is the repository-error one.
- **Submit with nothing staged** — a legitimate empty `resolutions` reply
  whose consequence is the conflicts re-check: exactly scenario 6's exit-8
  contract, pinned by
  `ResolveArmTests/emptyResolutionsWithConflictsRemainingExitsEight`.
