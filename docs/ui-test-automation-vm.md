# UI test automation in a Tart VM — Switchyard on cameron

**Status:** plan, not yet executed. Nothing in this document has been run for Switchyard yet;
every number quoted from the Changeover work is marked as measured there.

**Audience:** Claude / coding agents, working on cameron.

**Goal:** Switchyard's UI-facing test automations run inside a disposable macOS VM on cameron, so
they never touch the GUI session a human is using, and never accumulate TCC permission prompts on
the host.

---

## Why the VM is the policy going forward

Brennan's instruction, 2026-09-22: *"Going forward you should be doing all UI test automations
inside of a VM so it does not disrupt the user currently using this Mac. It also avoids all kinds
of permission issues."*

Two independent reasons, both already paid for once in this environment:

1. **Host safety.** `XCTAutomationSupport` loads into other running GUI apps and segfaulted Batty
   on gordon, killing ~38 terminal sessions (see
   `~/Developer/Homelab/cameron/tart-ui-test-vm.md` and
   `~/Developer/brennanMKE/Changeover/docs/ui-test-crash-prementation.md`). A VM guest is a
   separate macOS with its own WindowServer, apps and TCC database; the crash class cannot cross
   the guest boundary. On the host the only new processes are `tart` and Virtualization.framework's
   VM service.
2. **No permission debt.** UI automation on the host consumes TCC prompts (Screen Recording,
   Accessibility, Automation) that need a human to approve, and approvals accumulate. A guest
   destroyed after every run cannot accumulate approval debt; Automation Mode inside the guest is
   enabled **without authentication**, which is exactly what unattended runs need.

The template to copy is Changeover's, proven end to end on this machine:
`run-ui-tests-vm.sh` ran clone → boot → `xcodebuild test` in the guest → pull results → delete
clone in ~90 s wall clock, with `** TEST SUCCEEDED **`, zero prompts, all five of cameron's GUI
apps alive with the same ASNs, and no new crash reports (measured 2026-09-14, Changeover).

---

## What already exists on cameron (verified 2026-09-22)

| Fact | Value |
|---|---|
| Host | cameron, Apple M4 Pro, 64 GB RAM, macOS 27.0 |
| Tart | 2.32.1 installed via Homebrew (with `softnet` 0.19.0) |
| Golden image | `changeover-uitest-golden`, stopped, 140 GB allocated / ~87 GB actual |
| Source image | `ghcr.io/cirruslabs/macos-tahoe-xcode:26.5` (OCI layers cached in `~/.tart/cache`) |
| Guest macOS | 26.4 (25E246), user `admin`/`admin`, auto-logged-in, passwordless sudo |
| Guest Xcode | 26.6 (17F113) at `/Applications/Xcode_26.6.app`, selected; 26.5 copy still present |
| Guest sizing | 6 CPUs, 12288 MB |
| Guest hardening | Automation Mode without authentication, developer mode enabled, screen lock off, no sleep, SSH ACL empty (port 22 open but refuses every user) |
| Access | `tart exec` only (Tart Guest Agent); Remote Login is on cosmetically but unusable |

The Changeover golden image is a **general Xcode-in-Tart image**, not Changeover-specific: nothing
in it references the Changeover repository. Switchyard can clone it directly. Rename-or-share is a
DECISION below; the default plan shares it.

## What Switchyard needs that Changeover did not

Changeover's UI tests exercise a menu bar app with no window. Switchyard is a document-based
window app with real UI surface. Two consequences:

1. **Xcode 26.6 vs macOS 27 SDK.** Switchyard now builds against the macOS 27 SDK on the host
   (host macOS is 27.0, host Xcode 27.0 / 27A266a; the guest still has Xcode 26.6 on macOS 26.4).
   The guest Xcode must be upgraded to 27.0 before Switchyard's UI tests run there — same recipe
   the Changeover doc used: `ditto -c` the host Xcode to a CPIO on the host, share it read-only
   into the guest, `sudo ditto -x` inside the guest, `xcode-select`, accept license,
   `-runFirstLaunch`, `codesign --verify --strict`. Verify symlinks survive the extract (they did
   for 26.6; the CPIO method exists precisely because virtio-fs drops symlinks).
2. **Tests that need a running app.** Switchyard's UI automations drive a live app window
   (repository browser, history graph, context menus). The guest already has the right state for
   this: auto-login to an Aqua session, no screen lock, no sleep, Automation Mode without
   authentication. Where a test needs a repository to open, point it at a fixture repository
   shared read-only into the guest — **never** a live working copy, and never the primary
   checkout. Fixture repositories are cheap to regenerate inside the guest per run
   (`git init` + scripted commits), which avoids sharing anything at all.

SwiftUI behaviour spikes (#0381–#0386, 2026-09-22) established that some UI behaviours can only be
verified by a person at the Mac — hovering, key presses, disclosure clicks from an unattended
process need Accessibility. **Inside the guest, that constraint disappears for automation:**
Automation Mode without authentication means XCUITest can synthesize those interactions without a
prompt. The four blocked spike observations (#0382, #0383, #0385, #0386) are good first candidates
to re-derive as automated UI tests in the guest, with the caveat that the guest runs macOS 26.4 /
Xcode 26.6 today while the host behaviour was observed on macOS 27.0 / Xcode 27.0 — upgrade the
guest first (DECISION 1) so the answers transfer.

---

## Plan — phases for Switchyard

Each phase ends in a verifiable state. Copy the Changeover doc's discipline: record results in
this file as you go, mark anything unverified.

### Phase S0 — decide the sharing model

The Changeover golden image is generic. Options:

- **(a) Share it** (default): Switchyard clones `changeover-uitest-golden` directly. Zero new
  disk. Risk: a Switchyard-driven change to the golden (e.g. deleting `Xcode_26.5.app`) affects
  Changeover's runs.
- **(b) Clone-and-diverge**: `tart clone changeover-uitest-golden switchyard-uitest-golden`
  (APFS copy-on-write, cheap), then customize for Switchyard. Cost: ~83 GB of apparent disk, but
  COW means the real incremental cost is only what diverges.
- **(c) Fresh pull**: a Switchyard-specific image from the OCI cache. Most isolation, most disk.

**DECISION A — which sharing model?** Default if unanswered: (b), clone-and-diverge, because
Switchyard needs a different Xcode than Changeover does, and diverging Xcode versions inside one
shared golden recreates the "golden carries both Xcodes" problem the Changeover doc already
flagged.

### Phase S1 — upgrade the guest Xcode

Follow the Changeover recipe exactly (host CPIO archive → read-only share → `ditto -x` in guest →
select → license → first launch → codesign verify). Verified steps and their timings for Xcode
26.6 are in `tart-ui-test-vm.md` Phase 2; expect ~36 s pack, ~27 s unpack, 8.8 GB archive.

**DECISION 1 — Xcode version:** upgrade the guest to host Xcode 27.0 (27A266a) so guest and host
match, before any Switchyard test runs. Guest macOS 26.4 must first be confirmed to support it
(the 26.6 install needed macOS 26.2+; check the 27.0 `LSMinimumSystemVersion` on the host copy
before starting). If 27.0 needs a newer macOS than 26.4, a newer base image tag is required —
stop and record what `sw_vers` says in the guest and what the host Xcode requires, then ask.

**DECISION 2 — disk:** the host had 268 GiB free after the Changeover DerivedData clear; confirm
current free space and ask before deleting anything. Never delete host caches unprompted.

### Phase S2 — decide what "Switchyard UI tests" are

Switchyard has **no UI test target** today: `Switchyard.xcodeproj` has only `SwitchyardTests`
(unit tests; the empty `SwitchyardUITests` template residue was removed in #0355), and the
primary suite is `YardKit`'s swift-testing package (`swift test`, 1931 tests / 134 suites as of
2026-09-13). The engine and views live in the `YardUI` package target precisely so they are
reachable from `swift test` (guide §11 decision 10).

So Phase S2 is a scoping decision, not a port:

- **(a) New XCUITest target** (`SwitchyardUITests`) that launches the app and drives it — the
  Changeover shape. Needed for anything that must exercise the *running app* end to end.
- **(b) XCTest UI-adjacent tests in `SwitchyardTests`** that run inside the guest but do not
  synthesize interaction — cheap, but not what "UI test automation" usually means.
- **(c) SwiftPM-hosted UI verification** — run the spike app or a small harness executable inside
  the guest under Accessibility-free Automation Mode. Closest to what the spikes needed; not an
  XCUITest target at all.

**DECISION 3 — which shape?** Default if unanswered: (a) for the four blocked spike behaviours,
because XCUITest is the only mechanism that synthesizes hover/key/click against a real menu bar
and alert, and the guest's Automation Mode makes it prompt-free.

### Phase S3 — the run script

Copy `~/Developer/brennanMKE/Changeover/run-ui-tests-vm.sh` and adapt. Non-negotiables it already
encodes (do not re-derive them):

1. `set -euo pipefail`; run ID `switchyard-uitest-<YYYYMMDD>-<HHMMSS>-<pid>`; `trap` cleanup on
   `EXIT` **before** creating anything.
2. `git archive HEAD | tar -x` export — never the live working copy, never a Switchyard worktree
   with uncommitted round work.
3. The stale-clone sweep matches **only** its own run-id shape, never the golden (the 2026-09-13
   incident: an over-broad sweep deleted `changeover-uitest-golden` itself).
4. Read-only `--dir` share for the export; results come back through `tart exec` tar streaming,
   not through the share.
5. Secrets: Switchyard has none today (no `.xcconfig` secrets), so no equivalent of the TMDB-key
   cleanup — but keep the export deleted in the trap anyway.
6. Success criteria per run: `** TEST SUCCEEDED **`, no guest prompt, no new host crash reports,
   all cameron GUI apps alive (use `lsappinfo`, not `pgrep -x`), `tart list` clean.
7. Memory preflight: LM Studio models loaded on cameron can OOM-kill a run (mechanism in
   `tart-ui-test-vm.md` Known limits and `lm-studio-memory.md`). Reuse the memory-signal protocol
   or fail fast before cloning.

Location: **DECISION 4** — Changeover's script lives at its repo root; default for Switchyard is
`scripts/run-ui-tests-vm.sh` in this repository.

### Phase S4 — first run and evidence

One run, all success criteria green, results under `build/ui-tests/<run-id>/`. Record wall clock,
test count, and any prompt that appeared. Then the four blocked spike behaviours get their
automated re-derivation and their issues updated.

---

## Known limits (inherited from the Changeover work, all measured there)

- **Apple's 2-guest limit per host.** One run at a time.
- **Memory is the binding constraint**, not disk or CPU: LM Studio models loaded on cameron have
  OOM-killed a VM (and with it, a run's trap, leaving a stale clone). Preflight or coordinate.
- A run takes 6 CPUs and 12 GB from cameron; interactive work will feel the build.
- Every Xcode update means re-copying Xcode into the golden image.
- Guest GPU is paravirtualized — fine for Switchyard's views; the graph gutter is Canvas-drawn and
  should render correctly, but colour-accuracy claims in tests should tolerate it.

## Host-safety checklist (every run, before and after)

The point of the VM is that cameron is untouched. Verify it every time:

```sh
lsappinfo list | grep -E '^ *[0-9]+\) "'        # GUI apps alive, same ASNs
ls -lt ~/Library/Logs/DiagnosticReports | head  # no new crash reports
tart list                                       # no clones left behind
```

Anything unexpected → stop the automation work and report; do not debug inside a run.

## Open questions

1. Does Xcode 27.0 run on guest macOS 26.4, or is a newer base image needed? (Blocks Phase S1.)
2. Do Switchyard's package targets (`YardUI`, `YardKit`) build under the guest's toolchain
   unchanged, including `.defaultIsolation(MainActor.self)` on `YardUI`?
3. Does the Switchyard app need a repository fixture at launch, and should the fixture be
   generated per-run inside the guest or shared read-only from the host?
