# Manual review verification — `switchyard review --wait` (#0055)

The review round-trip needs a human looking at a real sheet in the running
app, so it cannot be exercised by `swift test`. The blocking semantics, the
wire types, the pending store, the sheet's model, and amend's apply path are
covered by the package suite (`YardKit/Tests/`); what this file owns is the
end-to-end behaviour with a real installed app.

**The rule (same as `scripts/verify-xpc.md`):** an issue that claims review
verification without naming a scenario number from this file has not verified
anything. Cite the scenario number and its outcome ("scenario 2: observed,
exit 0 and the envelope carried decision approve", "scenario 6: unrun on this
machine because …"). Every scenario below is **UNRUN**: written on the round
that built the feature, which cannot launch or install the app (signing
rules). Expected output is a *shape* derived from the source (`ReviewArm.swift`,
`AppXPCServer.swift`, `ReviewSheetBridge.swift`), not an observation — when
you run a scenario, paste what you saw into it and flip the mark.

## How a human runs this

1. **Build and install the app** (the CLI ships inside the app bundle and is
   linked at `/usr/local/bin/switchyard`; see `scripts/verify-install.md`).
   `switchyard review` never launches the app — it must already be running,
   or the scenario expects exit 3.
2. **For shape checks without the app**, a repo-built binary works:

   ```sh
   cd YardKit && swift build --product switchyard
   # binary at YardKit/.build/arm64-apple-macosx/debug/switchyard
   ```

3. **A review blocks**, so run it in the background with its stdout captured,
   decide in the app, then read the file and the status:

   ```sh
   switchyard review --staged --wait > review-out.json &
   reviewPid=$!
   # … decide in the sheet …
   wait $reviewPid; echo "exit=$?"
   cat review-out.json
   ```

## Exit codes

Every number below is a case of `ExitCode` (`YardKit/Sources/YardKit/ExitCode.swift`) —
cited by case name, never from memory. The JSON envelope carries the same
code as its `error.code` string (`ExitCode.codeLabel`), so stdout and the
process exit status always agree.

| Exit | Case | `error.code` | Meaning |
|---|---|---|---|
| 0 | `.success` | `ok` | Approve or amend; the result IS the reply |
| 1 | `.usage` | `usage` | Bad arguments (e.g. missing `--wait`) |
| 2 | `.brokerUnreachable` | `broker_unreachable` | Broker Mach service unreachable |
| 3 | `.appUnavailable` | `app_unavailable` | App not running and never launched |
| 4 | `.requestFailed` | `request_failed` | Superseded, or the app refused the request |
| 5 | `.sessionTerminated` | `session_terminated` | App quit mid-review — never a decision |
| 6 | `.repositoryError` | `repository_error` | Working directory is not a repository |
| 7 | `.humanDeclined` | `human_declined` | Rejected (envelope is still `"ok":true`) |
| 10 | `.timedOut` | `timed_out` | No decision within `--timeout` |

Success envelope: `{"ok":true,"result":{…},"schemaVersion":1}` with the result
being the reply (`decision`, optional `message`, `comments`, optional
`editedPatch`); failure envelope:
`{"error":{"code":"…","message":"…"},"ok":false,"schemaVersion":1}` with the
human-readable duplicate `[error] <code>: <message>` on stderr. Keys are
sorted; no trailing newline.

---

## Scenario 1 — App not running: exit 3, never a fallback — UNRUN

**Preconditions.** The app is not running and not launched on demand:
`pgrep -x Switchyard` prints nothing. The launch agent may be registered.

```sh
pgrep -x Switchyard                 # expect: no output
cd /path/to/some/repo
switchyard review --staged --wait
echo $?
```

**Expected** (shape): exit **3** (`.appUnavailable`), immediately, with

```json
{"error":{"code":"app_unavailable","message":"…"},"ok":false,"schemaVersion":1}
```

and no Switchyard pid appears afterwards (`pgrep -x Switchyard` still empty —
review never launches the app, the M4 exit criterion). **Fail** when: the
process hangs, a pid appears, or the exit is anything but 3.

---

## Scenario 2 — Real approve round-trip: exit 0 with the reply as the result — UNRUN

**Preconditions.** App running; a repository with a staged change:

```sh
cd /path/to/repo
echo "review me" >> a.txt && git add a.txt
switchyard review --staged --wait --timeout 120 > review-out.json &
reviewPid=$!
```

The app brings the repository's tab forward and presents the sheet with the
staged diff. Click **Approve** (optionally with a message).

```sh
wait $reviewPid; echo $?
cat review-out.json
```

**Expected** (shape): exit **0** (`.success`) and

```json
{"ok":true,"result":{"comments":[],"decision":"approve"},"schemaVersion":1}
```

— `result` IS the reply: `decision` of `approve`, `comments` (an array, here
empty), `message` present only if the human typed one, no `editedPatch`.
**Fail** when: the exit differs, `result.decision` is not `approve`, or the
envelope carries an `editedPatch` (approve never carries one).

---

## Scenario 3 — Reject: exit 7, envelope still `"ok":true` — UNRUN

**Preconditions.** As scenario 2.

```sh
switchyard review --staged --wait --timeout 120 > review-out.json &
reviewPid=$!
# … click Reject in the sheet …
wait $reviewPid; echo $?
cat review-out.json
```

**Expected** (shape): exit **7** (`.humanDeclined`) with stderr
`[error] human_declined: the review was rejected` and the envelope still
`"ok":true` — the JSON is the contract, the exit code is the signal:

```json
{"ok":true,"result":{"comments":[{"hunkID":"…","path":"…","text":"…"}],"decision":"reject"},"schemaVersion":1}
```

`comments` carries whatever per-hunk/per-line comments the human composed
(each with `path`, `hunkID`, optional `line`, `text`). **Fail** when the
envelope is `"ok":false` — a rejection is a decision, not an error.

---

## Scenario 4 — Amend with an edited patch: exit 0, patch on the wire, index amended — UNRUN

**Preconditions.** As scenario 2. The apply path matches against the **index**
(`git apply --cached`, `YardGit/Staging.swift`), so the human edits the patch
into the delta they want applied on top of the current index — the editor is
free text. Concretely: with `a.txt` staged as `review me\n`, edit the seeded
patch into

```text
diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1 +1 @@
-review me
+review me (amended)
```

then click **Send amend**.

```sh
wait $reviewPid; echo $?
cat review-out.json
git diff --cached          # the index, inspected AFTER the amend
```

**Expected** (shape): exit **0** (amend is not a rejection), the envelope
carries the patch for the agent's record,

```json
{"ok":true,"result":{"comments":[],"decision":"amend","editedPatch":"diff --git a/a.txt …"},"schemaVersion":1}
```

**and the index actually changed** — `git diff --cached` now shows
`+review me (amended)` where it showed `+review me` before. **Fail** when:
`editedPatch` is absent, the index is unchanged, or the exit is 7.

---

## Scenario 5 — A stale amend patch: typed error in the sheet, review still pending — UNRUN

**Preconditions.** As scenario 2. Click **Amend…** and send the seeded patch
**unedited**: for an already-staged review the index already holds the seed's
changes, so the apply must fail honestly ("does not apply") instead of
claiming success.

**Expected** (shape): the sheet shows the typed failure — "The edited patch
could not be applied to the index: …", with the guidance to edit and send
again or Cancel — and the CLI has NOT returned: the review is still pending.
Then click **Cancel** (the error clears) and **Approve**; the CLI returns
exit **0** with `decision` `approve`. **Fail** when: the sheet claims success,
the app crashes, the pending resolves on the failed amend, or the CLI exits
before the later approve.

---

## Scenario 6 — Timeout: exit 10, typed envelope — UNRUN

**Preconditions.** App running; any repository; the human answers nothing.

```sh
cd /path/to/repo
switchyard review --staged --wait --timeout 5
echo $?
```

**Expected** (shape): after ~5 s (the store's own typed timeout, which beats
the CLI's `--timeout + 5 s` backstop), exit **10** (`.timedOut`) with

```json
{"error":{"code":"timed_out","message":"no review decision arrived within 5s"},"ok":false,"schemaVersion":1}
```

stderr: `[error] timed_out: no review decision arrived within 5s`. The sheet
stays until the human closes its banner ("This review timed out before a
decision was made."). **Fail** when: exit 2, a hang past ~10 s, or a
decision-shaped envelope.

---

## Scenario 7 — App quits mid-review: exit 5, never a rejection — UNRUN

**Preconditions.** App running; a review in flight (scenario 2's shape).

```sh
switchyard review --staged --wait --timeout 120 > review-out.json &
reviewPid=$!
sleep 2
osascript -e 'quit app "Switchyard"'
wait $reviewPid; echo $?
cat review-out.json
```

**Expected** (shape): exit **5** (`.sessionTerminated`) with
`"code":"session_terminated"` — conflation with a rejection (7) would be the
serious bug the issue names: an agent must never read a crash as a considered
decision. **Fail** when: exit 7, `decision` anything, or a hang.

---

## Scenario 8 — No tab for the repository: opened and focused (#0084) — UNRUN

**Preconditions.** App running with at least one repository open, and a
second repository the app has no tab for.

```sh
cd /path/to/unopened/repo
switchyard review --staged --wait --timeout 120 > review-out.json &
reviewPid=$!
```

**Expected** (observed by the human): a tab for the unopened repository
appears in the frontmost window, is selected, and presents the review sheet —
no stray window, and the previously focused tab is untouched by a second
review later. Decide; `wait $reviewPid` exits **0**. **Fail** when: a new
window opens, the wrong tab is focused, or the sheet appears on the wrong
repository's tab.

---

## Scenario 9 — Two concurrent reviews on two repositories — UNRUN

**Preconditions.** App running; two repositories, each with a staged change.

```sh
cd /path/to/repoA && switchyard review --staged --wait --timeout 300 > "$PWD/review-a.json" &
cd /path/to/repoB && switchyard review --staged --wait --timeout 300 > "$PWD/review-b.json" &
wait
echo "A=$? (from repoA's shell)" # run each wait in its own shell, or capture per-job
```

(Simplest honest form: run each block in its own terminal.)

**Expected** (observed by the human): TWO sheets, one per repository, each on
its own tab; deciding one never blocks or dismisses the other. Approve in A
and reject in B: `review-a.json` is `decision` `approve` with exit **0**,
`review-b.json` is `decision` `reject` with exit **7**. **Fail** when either
CLI answers with the other repository's decision, or one review's sheet
disappears when the other is decided.

---

## Scenario 10 — A minutes-long review — UNRUN

The one Expected-behavior line only a human can prove: "Session survives a
long review — minutes, not seconds."

**Preconditions.** App running; any repository with a change to review. Start
a review with the default timeout (3600 s — a judgement, `ReviewArm.defaultTimeoutSeconds`),
leave the machine, come back after **at least five minutes** of real time,
then decide.

```sh
switchyard review --staged --wait > review-out.json &
reviewPid=$!
# … minutes pass; use the app, open other tabs, do other work …
wait $reviewPid; echo $?
cat review-out.json
```

**Expected** (observed by the human): the sheet is still there, still
interactive, the app never re-registered or dismissed it, and deciding
returns exit **0** with the reply. **Fail** when: the review timed out
before the human returned (check the banner), the sheet vanished, or the CLI
exited early with 5 or 10.

---

## Not scenarios here, and why

- **Superseded (exit 4)** — two `review --wait` runs for the SAME repository:
  covered by the package suite
  (`secondRequestForTheSameRepositorySupersedesTheFirst` and the CLI's
  superseded→exit-4 mapping, both fixture-determined); the manual form only
  re-proves the same store with a second terminal. Add it if a human ever
  reports supersede behaving oddly in the app.
- **Usage refusals (exit 1)** — `switchyard review --staged` without
  `--wait`, `--timeout x`: pure argv parsing, fully covered by
  `ReviewArmTests`; nothing app-side to observe.
- **Non-repository working directory (exit 6)** — covered end-to-end shape by
  `unresolvableWorkingDirectoryIsNeverRegistered`; the envelope is the
  repository-error failure envelope, not a review outcome.
