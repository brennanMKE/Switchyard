# Manual watch verification — `switchyard watch` (#0058)

Watch is the one M4 command with a real long-lived session, so its end-to-end
criteria — memory staying flat over a long stream, Ctrl-C on a real process,
the app quitting under a watcher — need a human at a machine with the app
installed. The package suite covers everything that does not need that: the
wire bytes (`WatchWireTests`), the session store's ordering/no-drop/scoping
semantics and its no-history bound (`WatchSessionStoreTests`), the arm's exit
mapping and 200- and 5000-event round trips over real anonymous XPC listeners
(`WatchArmTests`), and the hook-to-watch tap (`ReferenceTransactionHookTests`).
What this file owns is the end-to-end behaviour with a real installed app. It
is the sibling of `scripts/verify-review.md`, `scripts/verify-ask.md`,
`scripts/verify-resolve.md`, and `scripts/verify-xpc.md`.

**The rule (same as the siblings):** an issue that claims watch verification
without naming a scenario number from this file has not verified anything.
Cite the scenario number and its outcome ("scenario 2: observed, exit 0,
sequences restarted at 1 on the next watch"). Every scenario below is
**UNRUN**: written on the round that built the feature, which cannot launch or
install the app (signing rules). Expected output is a *shape* derived from the
source (`WatchArm.swift`, `WatchSessionStore.swift`, `WatchObservedBridge.swift`,
`ReferenceTransactionHook.swift`), not an observation — when you run a
scenario, paste what you saw into it and flip the mark.

## How a human runs this

1. **Build and install the app** (the CLI ships inside the app bundle and is
   linked at `/usr/local/bin/switchyard`; see `scripts/verify-install.md`).
   `watch` never launches the app — it must already be running, or the
   scenario expects exit 3 (`app_unavailable`).
2. **Two or more repositories registered**, so scoping has something to
   discriminate. A "watched repo" is one you can make a real commit in: the
   `reference-transaction` hook records it, and the hook's record is what the
   stream carries (`journal_observed`).
3. **Every long-running scenario** follows the same shape: run watch in the
   background with stdout captured, drive events from another shell, then
   read the file and the status.

   ```sh
   switchyard watch --timeout 600 > watch-out.jsonl &
   watchPid=$!
   # … drive events per the scenario …
   wait $watchPid; echo "exit=$?"
   wc -l watch-out.jsonl
   ```

## Scenarios

### Scenario 1 — the stream, end to end (baseline)

```sh
switchyard watch > watch-out.jsonl & watchPid=$!
cd /path/to/registered/repo && git commit --allow-empty -m "watch scenario 1"
wait $watchPid 2>/dev/null   # it will not exit; kill after reading
kill -INT $watchPid; wait $watchPid; echo "exit=$?"
cat watch-out.jsonl
```

**Expected**: one line per recorded transaction, each parsing as a JSON
object. The first line is the commit's record:

```json
{"kind":"journal_observed","payload":{"kind":"ref_updates","schemaVersion":1,
 "timestamp":"<ISO8601>","updates":[{"newValue":"<oid>","oldValue":"<oid>",
 "refName":"refs/heads/main"}],"worktree":{"name":"<name>","path":"<path>"}},
 "sequence":1}
```

(sequence and keys sorted by the encoder; `sequence` starts at 1 and every
further line increments it). The Ctrl-C detach exits **0** — scenario 2 owns
that half.

### Scenario 2 — Ctrl-C detaches cleanly, no orphaned session

```sh
switchyard watch > watch-out.jsonl & watchPid=$!
sleep 2
kill -INT $watchPid; wait $watchPid; echo "exit=$?"
# then, immediately: a fresh watch still gets a fresh stream
switchyard watch --timeout 3 > watch-out2.jsonl; echo "exit=$?"
head -1 watch-out2.jsonl
```

**Expected**: the interrupted watch exits **0** (a detach is a clean end,
never an error, never a stderr envelope). The follow-up watch registers a
fresh session — its first event carries `"sequence":1`. Sequences restarting
at 1 is the observable half of "no orphaned session": the killed CLI's
session was dropped app-side (the connection's invalidation handler drops
its own sessions), not left accumulating. A sequence that continues from the
killed session's counter means the old session leaked — fail, investigate.

### Scenario 3 — memory stays flat over a long session

The RemoteControl defect this scenario guards against was 940 MB of RSS
growth while streaming — invisible to a passing build and to a successful
short manual test. Measure, do not eyeball:

```sh
ps -o pid,rss -p $$   # note the shell's own rss as a control
switchyard watch --timeout 600 > watch-out.jsonl & watchPid=$!
for i in $(seq 1 2000); do
  git commit --allow-empty -q -m "watch scenario 3 $i"   # in a scratch repo
done
ps -o pid,rss -p $watchPid
kill -INT $watchPid; wait $watchPid; echo "exit=$?"
wc -l watch-out.jsonl
```

**Expected**: 2000 `journal_observed` lines (or one per commit; several
commits in one second may merge into one hook invocation — the count may be
lower, never the sequences gapped). The CLI's RSS after 2000 events should
sit within **10 MB** of its RSS after the first 10 — a stated constant and a
judgement, not a measured budget: the CLI writes each line to stdout as it
arrives and retains nothing per event (the buffer only exists when stdout is
not a live sink). Growth in the hundreds of MB is the defect; investigate
before ship. The app's RSS too: the app-side store retains no event history
by construction; a climbing app RSS over the same window points at a leak
the structure was supposed to make impossible.

### Scenario 4 — the app quits mid-watch (exit 5)

```sh
switchyard watch > watch-out.jsonl & watchPid=$!
sleep 2
osascript -e 'tell application "Switchyard" to quit'
wait $watchPid; echo "exit=$?"
cat watch-out.jsonl
```

**Expected**: exit **5**, and the output's last line is the
`session_terminated` failure envelope:

```json
{"error":{"code":"session_terminated","message":"the app terminated the watch session"}}
```

The stream lines before it (if any) are preserved on stdout ahead of the
envelope. A graceful quit ends sessions deliberately (`endAll(.appShutdown)`
in `applicationWillTerminate`); killing the app with SIGKILL instead should
reach the same exit 5 through connection death — try both; either outcome is
a pass for both only if both exit 5.

### Scenario 5 — `--timeout` detaches on its own (exit 0)

```sh
time switchyard watch --timeout 5; echo "exit=$?"
```

**Expected**: returns on its own after roughly five seconds (not exactly —
the deadline is the app's own timer, not a stopwatch), exit **0**, empty
stderr, no stdout lines. No Ctrl-C, no app quit: the session's own
`--timeout` is what ended it.

### Scenario 6 — repository scoping

```sh
switchyard watch > all.jsonl &                    # all repositories
switchyard watch --repository /path/to/repo-a > a.jsonl &
cd /path/to/repo-a && git commit --allow-empty -q -m "scenario 6 a"
cd /path/to/repo-b && git commit --allow-empty -q -m "scenario 6 b"
sleep 1; kill -INT %1 %2; wait; echo "exit=$?"
```

**Expected**: `all.jsonl` has both commits' records (its sequences
1, 2, … across both); `a.jsonl` has only repo-a's record — and, because
numbering is per session, its own sequence starts at 1. An event for repo-b
appearing in `a.jsonl` is a scoping defect.

### Scenario 7 — the app is down (exit 3)

Quit the app, then:

```sh
switchyard watch; echo "exit=$?"
```

**Expected**: exit **3** and the `app_unavailable` failure envelope on
stdout. Watch never launches the app (`launchIfNeeded: false` is the M4
criterion) — if the app started, that is a defect, not a convenience.

### Scenario 8 — the broker restarts under a watch

```sh
switchyard watch > watch-out.jsonl & watchPid=$!
sleep 2
launchctl kickstart -k gui/$UID/co.sstools.Switchyard.broker
cd /path/to/registered/repo && git commit --allow-empty -q -m "scenario 8"
sleep 2; kill -INT $watchPid; wait $watchPid; echo "exit=$?"
cat watch-out.jsonl
```

**Expected**: the watch session is unaffected — the CLI's live connection is
to the app's endpoint, not to the broker, which only answers endpoint
discovery at connect time. The commit's record still arrives after the
restart; exit 0 on the detach. If the stream dies with the broker, the
session is broker-coupled — investigate against #0047's re-registration
shape before ship.
