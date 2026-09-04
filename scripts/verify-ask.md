# Manual ask verification — `switchyard ask` (#0056)

The ask round-trip needs a human looking at a real sheet in the running app,
so it cannot be exercised by `swift test`. The blocking semantics, the FIFO
queue, the wire types, the pending store, the sheet's model, and the arm's
exit mapping are covered by the package suite (`YardKit/Tests/`); what this
file owns is the end-to-end behaviour with a real installed app. It is the
sibling of `scripts/verify-review.md`, generalised from review to ask.

**The rule (same as `scripts/verify-review.md`):** an issue that claims ask
verification without naming a scenario number from this file has not verified
anything. Cite the scenario number and its outcome. Every scenario below is
**UNRUN**: written on the round that built the feature, which cannot launch
or install the app (signing rules). Expected output is a *shape* derived from
the source (`AskArm.swift`, `PendingAskStore.swift`, `AskSheetBridge.swift`),
not an observation — when you run a scenario, paste what you saw into it and
flip the mark.

## How a human runs this

1. **Build and install the app** (the CLI ships inside the app bundle and is
   linked at `/usr/local/bin/switchyard`; see `scripts/verify-install.md`).
   `switchyard ask` never launches the app — it must already be running, or
   the scenario expects exit 3.
2. **An ask blocks**, so run it in the background with its stdout captured,
   answer in the app, then read the file and the status:

   ```sh
   switchyard ask "Deploy now?" --options yes,no > ask-out.json &
   askPid=$!
   # … answer or decline in the sheet …
   wait $askPid; echo "exit=$?"
   cat ask-out.json
   ```

## Exit codes

Every number below is a case of `ExitCode` (`YardKit/Sources/YardKit/ExitCode.swift`) —
cited by case name, never from memory.

| Exit | Case | `error.code` | Meaning |
|---|---|---|---|
| 0 | `.success` | `ok` | An option was picked; the result IS the reply |
| 1 | `.usage` | `usage` | Bad arguments (e.g. no `--options`, an empty option) |
| 3 | `.appUnavailable` | `app_unavailable` | App not running and never launched |
| 5 | `.sessionTerminated` | `session_terminated` | App quit mid-ask — never a decision |
| 7 | `.humanDeclined` | `human_declined` | The human declined to answer (envelope is still `"ok":true`) |
| 10 | `.timedOut` | `timed_out` | No answer within `--timeout` |

Success envelope: `{"ok":true,"result":{…},"schemaVersion":1}` with the result
being the reply (`optionIndex`, `optionText`, optional `message`, or
`declined:true` for a decline); failure envelope:
`{"error":{"code":"…","message":"…"},"ok":false,"schemaVersion":1}` with the
human-readable duplicate `[error] <code>: <message>` on stderr. Keys are
sorted; no trailing newline.

---

## Scenario 1 — App not running: exit 3, never a fallback — UNRUN

**Preconditions.** The app is not running: `pgrep -x Switchyard` prints
nothing.

```sh
pgrep -x Switchyard                 # expect: no output
cd /path/to/some/repo
switchyard ask "Deploy now?" --options yes,no
echo $?                             # expect: 3
```

Expect stdout `{"error":{"code":"app_unavailable",…},"ok":false,…}` and
stderr `[error] app_unavailable: …`. The app must NOT be launched.

## Scenario 2 — An option is picked: exit 0, the payload is the reply — UNRUN

```sh
cd /path/to/some/repo
switchyard ask "Deploy now?" --options yes,no > ask-out.json &
askPid=$!
# click "no", type "staging only" in the message field
wait $askPid; echo $?               # expect: 0
cat ask-out.json
```

Expect the sheet on the tab for the repository (routed there via #0084), and
stdout `{"ok":true,"result":{"message":"staging only","optionIndex":1,
"optionText":"no"},"schemaVersion":1}`.

## Scenario 3 — The human declines: exit 7, envelope still ok:true — UNRUN

```sh
cd /path/to/some/repo
switchyard ask "Deploy now?" --options yes,no > ask-out.json &
askPid=$!
# click "Decline to answer"
wait $askPid; echo $?               # expect: 7
cat ask-out.json
```

Expect stdout `{"ok":true,"result":{"declined":true},"schemaVersion":1}` (or
with a `"message"` key if the human typed one) and stderr
`[error] human_declined: …`.

## Scenario 4 — Timeout: exit 10, a typed outcome, never a decline — UNRUN

```sh
cd /path/to/some/repo
switchyard ask "Deploy now?" --options yes,no --timeout 5
echo $?                             # expect: 10 (after ~5 s, without touching the sheet)
```

Expect stdout `{"error":{"code":"timed_out",…},"ok":false,…}`. The sheet
shows the timed-out banner and its buttons disable.

## Scenario 5 — A second ask for the same repository queues — UNRUN

```sh
cd /path/to/some/repo
switchyard ask "First?" --options a,b > first.json &
firstPid=$!
switchyard ask "Second?" --options a,b > second.json &
secondPid=$!
# the sheet shows "First?" — answer it
# the sheet then shows "Second?" — answer it
wait $firstPid $secondPid; echo $?
```

Expect the first ask to present first, the second NOT to replace it, and both
processes to exit 0 once each is answered in queue order.

## Scenario 6 — The question renders as text, never markup — UNRUN

```sh
cd /path/to/some/repo
switchyard ask 'Run <script>alert("x")</script>? [click](http://evil.example)' --options yes,no
```

Expect the sheet to show those bytes literally — no alert, no link, no bold —
because the question is rendered through `Text(verbatim:)`.

## Scenario 7 — Usage refusals: exit 1 before any connection — UNRUN

```sh
switchyard ask "Deploy now?"                    # expect: 1 (no --options)
switchyard ask "Deploy now?" --options "yes,,no" # expect: 1 (empty option)
switchyard ask --options yes,no                 # expect: 1 (no question)
switchyard ask "Q?" --options yes,no --timeout abc  # expect: 1
```

Each must exit 1 with a `usage` envelope and never reach the app.
