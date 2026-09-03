# Manual XPC verification for `switchyard`

UI tests cannot run under CLI-driven `xcodebuild` in this environment — the runner times out
enabling automation mode because it lacks Accessibility rights (issue #0054). XPC behavior is
verified here instead: a human runs pasteable commands and reads the results.

**The rule: an issue that claims XPC verification without naming a scenario number from this file
has not verified anything.** Cite the scenario number and its outcome ("scenario 4: observed,
payload named the CLI's repository", "scenario 3: unrun on this machine because …").

## How a human runs this

1. **Build and install the app.** The CLI ships inside the app bundle (#0050):
   `Contents/Resources/bin/switchyard`, and the app's install action links it at
   `/usr/local/bin/switchyard`. Launching the app once also registers the broker launch agent
   (`SMAppService.agent(plistName: "co.sstools.Switchyard.broker.plist")`, `Switchyard/AgentRegistrar.swift`).
2. **For the scenarios that do not need the app, a repo-built binary works:**

   ```sh
   cd YardKit && swift build --product switchyard
   # binary at YardKit/.build/arm64-apple-macosx/debug/switchyard — substitute this path
   # wherever a command below says `switchyard`
   ```

3. **Check machine state first** (read-only; changes nothing):

   ```sh
   launchctl print gui/$UID/co.sstools.Switchyard.broker   # registered agent? running?
   pgrep -x Switchyard                                      # is the app running?
   ```

4. **Read the statuses.** Every scenario below is marked **RUN** (executed on the round that wrote
   this file, real output pasted) or **UNRUN** (not executable on that machine/round, reason
   stated). Expected output for an UNRUN scenario is a *shape* derived from the source, not an
   observation — when you run it, paste what you saw into this file and flip the mark.

## Exit codes

Every number below is a case of `ExitCode` (`YardKit/Sources/YardKit/ExitCode.swift`) — cited by
case name, never from memory. The JSON failure envelope carries the same code as its
`error.code` string (`ExitCode.codeLabel`), so stdout and the process exit status always agree.

| Exit | Case | `error.code` | Meaning |
|---|---|---|---|
| 0 | `.success` | `ok` | Completed; success envelope on stdout |
| 1 | `.usage` | `usage` | Bad arguments or unknown subcommand |
| 2 | `.brokerUnreachable` | `broker_unreachable` | Broker Mach service could not be contacted |
| 3 | `.appUnavailable` | `app_unavailable` | Broker reachable but no app, or app not installed |
| 4 | `.requestFailed` | `request_failed` | Delivered but the request failed |
| 5 | `.sessionTerminated` | `session_terminated` | The app terminated the XPC session |
| 6 | `.repositoryError` | `repository_error` | Working directory is not a usable repository |

Envelope shapes (sorted keys, no trailing newline on stdout): success is
`{"ok":true,"result":{…},"schemaVersion":1}`; failure is
`{"error":{"code":"…","message":"…"},"ok":false,"schemaVersion":1}`, with the human-readable
duplicate `[error] <code>: <message>` on **stderr**.

---

## Scenario 1 — Nothing registered at all — RUN 2026-09-03

**Preconditions.** The launch agent is not registered and the app is not running. Verified
read-only before running anything:

```sh
launchctl print gui/$UID/co.sstools.Switchyard.broker
pgrep -x Switchyard
```

Observed on this round's machine (macOS 26.6.2, Apple M4 Pro, arm64):

```text
$ launchctl print gui/$UID/co.sstools.Switchyard.broker
Bad request.
Could not find service "co.sstools.Switchyard.broker" in domain for user gui: 501
$ pgrep -x Switchyard
$                                   # no output, exit 1 — the app is not running
```

**Command.** The planning update named `switchyard noop` here; **that does not hold on this
build** — `noop` is answered locally (`localCommandNames`, `CommandLineRunner.swift:16`) and never
touches XPC. Observed:

```text
$ switchyard noop
{"ok":true,"schemaVersion":1}
$ echo $?
0
```

The probe that actually exercises the broker path is any *known remote* command — `whereami`,
`status`, `log`, … (see `CommandRegistry.all`). Run it from any directory:

```sh
switchyard whereami
```

**Expected** (observed):

```text
$ switchyard whereami
{"error":{"code":"broker_unreachable","message":"cannot reach the broker: Couldn’t communicate with a helper application."},"ok":false,"schemaVersion":1}
$ echo $?
2
```

stderr: `[error] broker_unreachable: cannot reach the broker: Couldn’t communicate with a helper
application.`

**Pass** when: exit **2** (`ExitCode.brokerUnreachable`), the envelope carries
`"error":{"code":"broker_unreachable",…}`, and the command returns immediately (no launch attempt —
the broker is unreachable before any launch decision, `Dispatch.swift` routes `.remote` →
`AppConnection.connect` → `broker.appEndpoint()` throws first). **Fail** when: any other exit code,
or the process hangs.

---

## Scenario 2 — Broker ping with the app closed — UNRUN

**Preconditions.** App installed and launched once (agent registered), then the app quit:
`launchctl print gui/$UID/co.sstools.Switchyard.broker` shows the job, `pgrep -x Switchyard` is
empty.

**What it proves.** launchd starts the broker on demand and it answers with the app closed — the
acceptance probe `BrokerProtocol.brokerPing` was written for (#0046, `XPCProtocols.swift:25`).

**Why it is UNRUN.** Two blockers, either alone sufficient:

1. The launch agent cannot be registered without installing/launching the app (forbidden on the
   round that wrote this file — see the machine-state record under scenario 1).
2. **No CLI subcommand reaches `brokerPing` today.** `BrokerConnection.ping()`
   (`BrokerConnection.swift:84`) exists, but nothing in `CommandRegistry.all` calls it, and every
   remote command goes through `appEndpoint` + launch-on-demand, which *launches* the app rather
   than leaving it closed. The scenario needs a `switchyard ping` subcommand (or equivalent)
   before a human can run it as written.

**When it exists, the check is:** record the agent's state before
(`launchctl print …` → `state = not running`, no pid), run the ping subcommand, observe exit 0 with
`"ok":true`, and confirm the agent now has a pid in `launchctl print` while `pgrep -x Switchyard`
is still empty. **Fail** when exit **2** (`.brokerUnreachable` — launchd did not start the agent)
or the app appears in `pgrep`.

---

## Scenario 3 — On-demand app launch; `--no-launch` — UNRUN

**Preconditions.** Agent registered (scenario 2's state), app installed and **not running**.

**Part A — launch on demand.**

```sh
pgrep -x Switchyard        # expect: no output
switchyard whereami        # run inside any git repository
pgrep -x Switchyard        # expect: one pid, printed
```

**Expected:** the first `pgrep` prints nothing; the second prints a pid; the command exits **0**
(`.success`) with a whereami payload naming the repository the CLI ran in (shape under scenario 4).
**Fail** when exit **3** (`.appUnavailable`) with the app still closed, or any exit with no new pid.

**Part B — `--no-launch`. The flag is not wired at the CLI level. UNRUN.**
`AppConnection.connect(launchIfNeeded:requireApp:)` (`AppConnection.swift:47-51`) implements the
behavior — `launchIfNeeded: false` throws `.appUnavailable` instead of launching — but it exists as
a *parameter*; `dispatch` calls `connect()` with the defaults and passes argv through verbatim
(`Dispatch.swift:31`). Guide §10 lists adding the CLI flag as pending work. Expected once wired:

```sh
pgrep -x Switchyard              # expect: no output
switchyard whereami --no-launch  # expected once the flag exists: exit 3, nothing launches
pgrep -x Switchyard              # expect: still no output
```

**Expected:** exit **3** (`.appUnavailable`), envelope (shape, not observed):

```json
{"error":{"code":"app_unavailable","message":"the broker is reachable but no app endpoint is registered"},"ok":false,"schemaVersion":1}
```

**Fail** when a Switchyard pid appears — that means the app was launched despite `--no-launch`.

---

## Scenario 4 — Live data from the running app — UNRUN

**Preconditions.** App running (or launched on demand), agent registered. Two *different* git
repositories.

**What it proves.** `workingDirectory` is marshalled over the wire (guide §11 decision 15): the
answer reflects the repository the CLI was invoked in, not the app's own working directory.

```sh
cd /path/to/repoA && switchyard whereami
cd /path/to/repoB && switchyard whereami
```

**Expected:** exit **0** (`.success`) both times; each envelope's payload describes *its own*
repository — `"branch"` differs per repo, `"headOID"` matches each repo's HEAD. Payload keys (from
`whereamiSpec`, `CommandRegistry.swift:50-91`): `branch`, `upstream`, `ahead`, `behind`,
`isMidRebase`, `isMidMerge`, `isMidCherryPick`, `stashCount`, `untrackedCount`, `unstagedCount`,
`stagedCount`, `hasConflicts`, `conflictCount`, `headOID`, `rawHead`. Success shape:

```json
{"ok":true,"result":{"branch":"…","conflictCount":0,"hasConflicts":false,"headOID":"…","isMidCherryPick":false,"isMidMerge":false,"isMidRebase":false,"rawHead":"…","stagedCount":0,"stashCount":0,"untrackedCount":0,"unstagedCount":0},"schemaVersion":1}
```

**Fail** when: both answers describe the same repository, or the payload does not match the
repository the shell was cd'd into.

**Inspection note (not an observation):** on the tree this file was written from, the app's
`perform` forwards to `performCommand` → `runYard` (`AppXPCServer.swift:240`,
`CommandLineRunner.swift:136`), and `runYard` answers every remote command with the usage envelope
"Unknown subcommand 'whereami'", exit **1** (`.usage`) — `runEngineCommand`
(`YardCommands/EngineCommands.swift:11`) has no caller in the app target (only the `yard-engine`
dev harness calls it). If you observe exit 1 with `"code":"usage"`, the transport is fine and the
engine arm is not wired into the app's XPC server yet; that is a real defect this scenario exists
to catch, not a pass.

---

## Scenario 5 — App quits mid-request — UNRUN

**Preconditions.** App running, agent registered.

```sh
switchyard whereami &
sleep 1
osascript -e 'quit app "Switchyard"'
wait; echo $?
```

**Expected:** exit **5** (`.sessionTerminated`, `AppConnectionError.appTerminated` →
`AppConnectionError.exitCode`), envelope (shape, not observed — the underlying text varies):

```json
{"error":{"code":"session_terminated","message":"lost the connection to the app: …"},"ok":false,"schemaVersion":1}
```

**No hang:** the CLI waits at most 5 seconds (`AppConnection.perform` default timeout,
`AppConnection.swift:181`). If the app wedges instead of quitting, the timeout fires and maps to
exit **2** with `"message":"timed out after 5.0s"` (`CLIError.timedOut` → `.brokerUnreachable`) —
also acceptable as "no hang", but it means the termination path did not run. **Fail** when: the
CLI returns an unrelated code, or hangs past the 5-second bound.

---

## Scenario 6 — Broker restarted under the app — UNRUN

**Preconditions.** App running (its endpoint is registered), agent registered. This is the only
scenario that exercises re-registration — the reason #0047 wrote the `interruptionHandler`
(`Switchyard/AppXPCServer.swift:143`).

```sh
launchctl print gui/$UID/co.sstools.Switchyard.broker | grep -E 'pid|state'
launchctl kickstart -k gui/$UID/co.sstools.Switchyard.broker
sleep 2
cd /path/to/repoA && switchyard whereami
```

**Expected:** after the kickstart the broker has a **new** pid (the registry it holds is empty —
the app's old registration died with the old broker process); the app's `interruptionHandler`
re-registers (`registerWithBroker`); the command then exits **0** (`.success`) with the whereami
payload for `repoA`. Confirm re-registration in the log:

```sh
/usr/bin/log show --last 1m --predicate 'subsystem == "co.sstools.Switchyard"' | grep -i "re-registering"
# expect: "broker connection interrupted, re-registering"  (AppXPCServer.swift:145)
```

**Fail** when: the command exits **3** — the restarted broker answered `appEndpoint` with nil, so
the re-registration did not happen in time (retry once before failing the scenario; the handler is
async). **Why UNRUN:** `kickstart` changes launchd state and the app must be running — both
forbidden on the writing round.

---

## Scenario 7 — Two concurrent CLIs, two repositories — UNRUN

**Preconditions.** App running, agent registered.

```sh
cd /path/to/repoA && switchyard whereami > "$PWD/switchyard-a.json" &
cd /path/to/repoB && switchyard whereami > "$PWD/switchyard-b.json" &
wait
```

(`/path/to/repoA` and `/path/to/repoB` are placeholders — substitute two real repositories. The
two invocations must overlap in time; the JSON files land beside each repository.)

**Expected:** both exit **0**; `repoA`'s envelope names `repoA`'s branch/HEAD and `repoB`'s names
`repoB`'s. One accepted connection per CLI, one exported `AppService` per connection, no session
state (`AppXPCServer.swift:188-191`) — interleaving is safe by construction, which is what this
scenario checks in practice. **Fail** when an answer describes the other repository, or either
command fails. **Why UNRUN:** needs the app running.

---

## Scenario 8 — The #0053 `@Sendable` failure paths — UNRUN

**What it proves.** The XPC reply/error closures run without the off-isolation `SIGTRAP` crash
that `@Sendable`-less handlers trap with (RemoteControl's
`docs/swift-concurrency-and-xpc.md` §1; the annotated handlers:
`AppConnection.swift:205-208`, `BrokerConnection.swift:120-122`, `AppXPCServer.swift:143,153`).
#0053's planning update assigns these here; they cannot be reached from `swift test`.

**Part A — kill the app mid-request.**

```sh
switchyard whereami &
sleep 1
pkill -9 -x Switchyard
wait; echo $?
ls -t ~/Library/Logs/DiagnosticReports/ | head        # expect: no new Switchyard crash report
```

**Expected:** exit **5** (`.sessionTerminated`) with the scenario-5 envelope shape — a normal
error-handler resumption, **not** `Trace/BPT trap` (exit 133) — and no new
`Switchyard-*.ips` crash report. **Fail** when: the CLI dies by signal, or a crash report appears.

**Part B — restart the broker under the running app.** Scenario 6's kickstart, plus the same
crash-report check on the **app**: expected exit **0** after re-registration and no crash report.
**Fail** when the app dies by SIGTRAP or the command exits 3. **Why UNRUN:** both parts need the
app running / the agent registered.

---

## Cold-start latency — the one measurement this script owns — UNRUN

#0048 lists cold-start as a criterion and cannot measure it from `swift test`. With the app closed
and the agent registered (scenario 2's state), time a command that needs the app, three runs:

```sh
/usr/bin/time -p switchyard whereami
```

Record the real `real` seconds from all three runs, and note the machine. The launch-on-demand
path bounds the wait at 10 seconds (`launchTimeout`, `AppConnection.swift:50`); `user`/`sys` from
`time -p` cover the CLI process only — the app launch cost lands in `real`. **Why UNRUN:** the
agent is not registered on this machine and registering it is forbidden on the writing round.

---

## Dropped from the original list, and why

The original Expected behavior list in #0054 named five coverage areas. Two are **not scenarios
here because Switchyard has not chosen to build the features they describe** (planning update,
2026-08-17):

- **App-pushed events** — the app calling *into* the CLI, unprompted, is RemoteControl's
  long-lived-session model. Guide §11 decision 15 settles Switchyard's wire as **argv in, a
  rendered envelope out**; there is no reverse channel to verify.
- **Streaming progress** — same origin, same verdict: a session with the app streaming back to an
  attached CLI is not a Switchyard feature. #0213 (sessions) closed wontfix; session state is
  #0349 / M4 and deliberately after this. Writing scenarios for either would document a design
  nobody has adopted.

Also dropped from the original failure list:

- **CLI killed mid-session** — with no long-lived session (#0213 wontfix) there is nothing to
  observe beyond the process dying: no cleanup exists to verify, and the broker/app never learn
  the CLI was there (each request is one stateless `perform` round trip).

Everything else from the original list survives as scenarios 1-8 above. The list is closed: do not
add scenarios for features the guide has not settled.
