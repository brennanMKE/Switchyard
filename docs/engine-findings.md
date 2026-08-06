# Engine findings (M0)

Output of the Milestone 0 spike. Each finding records what was actually run and what was observed,
not a conclusion alone. The spike code under `spike/` is deleted by #0005 once this document is
complete.

**Machine:** macOS 26 (Darwin 25.5.0), Apple Silicon. git 2.50.1 (Apple Git-155), Swift 6.3.3,
Xcode 26.6, Homebrew 6.0.15.

**Status:** #0001 partial (route A evaluated), #0004 **complete and negative**, #0002 and #0003
not yet run.

---

## #0004 — Does the chosen libgit2 build work against a reftable repository?

### Answer: No. Not partially — it cannot open one at all.

libgit2 **1.9.6**, the current Homebrew stable *and the latest upstream release*, fails at
`git_repository_open` on a repository created with `git init --ref-format=reftable`:

```
[FAIL] open repository — unsupported extension name extensions.refstorage
```

This is not a degraded read path returning empty results. The repository handle is never created,
so every subsequent libgit2 call is unreachable. Two fixtures built identically apart from ref
format, probed by the same binary:

| Probe | `files` fixture | `reftable` fixture |
|---|---|---|
| open repository | PASS | **FAIL — unsupported extension** |
| enumerate refs | PASS (3 refs) | unreachable |
| resolve `HEAD` | PASS | unreachable |
| read `HEAD` reflog | PASS (3 entries) | unreachable |
| walk commits | PASS | unreachable |

The same binary against `git/git` (81,873 commits, `files` format): all probes pass, 1,018 refs
enumerated.

### This is an upstream gap, not a packaging mistake

- **v1.9.6 is the latest libgit2 release.** Homebrew is not behind; there is no newer tag to move to.
- **The implementation exists in `main`**: `src/libgit2/refdb_reftable.c`, `refdb_reftable.h`, and a
  vendored `deps/reftable/`.
- **The tracking issue "reftable support for libgit2" is still open.** So the code is merged but
  unreleased — precisely the "merged is not the same as in a tagged release you can build against"
  distinction the development guide flagged.

### The fallback works completely

Every primitive the journal and graph need was run against the **same** reftable repository libgit2
refused to open:

| Command | Result |
|---|---|
| `git for-each-ref` | `refs/heads/feature-x refs/heads/main refs/tags/v1` |
| `git rev-list --count HEAD` | `3` |
| `git symbolic-ref HEAD` | `refs/heads/main` |
| `git reflog` | 3 entries |
| `git rev-parse --git-dir --git-common-dir` | `.git .git` |
| `git stash create` | empty (clean tree — expected) |
| `git update-ref refs/switchyard/journal/test HEAD` | ref created, resolves to `9c2e51043c` |

`update-ref` mattering most here: journal anchor refs (#0028) are how snapshots survive `gc`, and
they work on reftable through plumbing.

### Consequence for the architecture

Guide §5's hybrid boundary shifts toward the CLI, as the guide anticipated it might. **Ref
enumeration, `HEAD` resolution, reflog reading, and DAG traversal go through `git` plumbing, not
libgit2.** libgit2 remains a candidate for the object database, diff, blame, and merge — none of
which the reftable extension affects.

This must be settled before M1 starts. It is not a retrofit: it decides what `WorktreeContext`
(#0009) and the graph engine (#0015) are built on.

**Three options, and the choice is Brennan's:**

1. **Plumbing for refs, libgit2 for objects** — what the guide already prescribes. Works today
   against both ref formats. Costs a `git` process per ref operation, which #0003 must then measure
   for the graph path specifically.
2. **Vendor libgit2 from `main`** to get `refdb_reftable.c`. Gets reftable *and* keeps refs in-process
   — but means building unreleased C from a moving branch, and libgit2 builds with CMake, which
   SwiftPM cannot drive without a binary target or a prebuilt `xcframework`. Real packaging work,
   and a security-update story that is ours rather than Homebrew's.
3. **Drop libgit2 entirely for the git CLI**, which is what Zed did in June 2026. Removes the
   dependency question, at the cost of a process per operation everywhere and losing in-process
   diff/merge.

**Recommendation: option 1 for now**, and let #0003 decide whether the plumbing cost is acceptable
on the graph path. If it is not, option 2 becomes worth its packaging cost, and #0003's numbers are
what would justify it. Deciding before measuring would be guessing.

---

## #0001 — How does libgit2 get into a SwiftPM package in 2026?

### Route A: `systemLibrary` target + Homebrew — works

```swift
.systemLibrary(
    name: "Clibgit2",
    path: "Sources/Clibgit2",
    pkgConfig: "libgit2",
    providers: [.brew(["libgit2"])]
)
```

with a `module.modulemap` declaring `header "shim.h"`, `link "git2"`, and a `shim.h` of
`#include <git2.h>`. Builds and links clean, and the resulting binary calls libgit2 successfully
against real repositories (see #0004 above).

Findings worth recording:

- **`pkg-config` is a required, undeclared dependency.** It was not installed on this machine, and
  `providers: [.brew(["libgit2"])]` does not install it. Without it the `pkgConfig:` lookup cannot
  resolve. Anyone building Switchyard needs both `libgit2` and `pkg-config` from Homebrew, so this
  belongs in the README build instructions, not discovered at first build.
- **Homebrew is not on the default non-interactive `PATH`.** `swift build` needed
  `PATH=/opt/homebrew/bin:$PATH` to find `pkg-config`. This will bite CI (#0076) and the Xcode
  run-script phase (#0050), both of which run with a reduced environment.
- **Swift 6 top-level actor isolation.** Top-level code is `@MainActor` but top-level functions are
  not, so a helper mutating a top-level `var` fails to compile. Not libgit2-specific, but the app
  target already sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and will hit the same class of
  error.

**Unresolved for route A:** Homebrew installs per-architecture into `/opt/homebrew` (Apple Silicon)
or `/usr/local` (Intel), and a distributed app cannot depend on a user's Homebrew. This route is
viable for development but **not for shipping**, since the embedded `yard` (#0050) must run on a
machine with no Homebrew at all.

### Routes B and C: not yet evaluated

- **Route B, vendored C target.** libgit2 builds with CMake; SwiftPM cannot drive CMake directly, so
  this likely means a prebuilt `xcframework` consumed as a `binaryTarget`. This is also the route
  that would unlock reftable via `main` (option 2 above).
- **Route C, existing Swift bindings.** SwiftGit2 and ObjectiveGit both need a staleness check
  before being depended on, per the guide.

A `gitoxide` (Rust) bridge remains the documented alternative if libgit2 proves unworkable.

**Route A being development-only is the important open thread**: whatever ships must be
self-contained inside the app bundle.

---

## #0002 — SSH-signed commits through libgit2

Not yet run. Partially blocked: the "GitHub reports the commit as verified" criterion needs a push
to a scratch repository under Brennan's account and an SSH signing key registered there.

## #0003 — Graph performance on a 50k+ commit repository

### Answer: fast enough, but only on the plumbing path with a commit-graph.

**Fixture:** `../git` (the git/git repository), 81,873 commits, 1,018 refs, 376 MB, `files` ref
format. Release build, Apple Silicon. Times are load (walk commits collecting oid + parents) and
lanes (assign lanes over those nodes) separately.

**Without a commit-graph file:**

| Window | libgit2 load | plumbing load | lanes |
|---|---|---|---|
| 100 | 451 ms | 391 ms | 0.1 ms |
| 200 | 446 ms | 396 ms | 0.4 ms |
| 1,000 | 574 ms | 397 ms | 7 ms |
| 5,000 | 451 ms | 415 ms | 142 ms |
| 20,000 | 461 ms | 463 ms | 2,142 ms |

**With a commit-graph file** (`git commit-graph write --reachable`: **0.39 s**, 5.1 MB):

| Window | libgit2 load | plumbing load | lanes |
|---|---|---|---|
| 100 | 456 ms | **79 ms** | 0.1 ms |
| 200 | 440 ms | **77 ms** | 0.4 ms |
| 1,000 | 450 ms | **86 ms** | 7 ms |
| 5,000 | 449 ms | **101 ms** | 148 ms |
| 20,000 | 457 ms | **150 ms** | 2,155 ms |

### Three findings, in order of how much they change the design

**1. `git` plumbing uses the commit-graph. libgit2 1.9.6, as measured, does not.** Plumbing drops
from 391 ms to 79 ms for a 100-commit window — roughly 5×. libgit2 does not move at all: 451 ms
before, 456 ms after. Caveat worth stating plainly: this is an observation about a default-configured
libgit2, not proof it cannot use a commit-graph. But nothing had to be configured to get the win on
the plumbing side, and that asymmetry is the point.

**2. Topological order costs a full history traversal regardless of window size.** A 100-commit
window costs the same as a 20,000-commit window on the load side — 451 ms vs 461 ms without a
commit-graph. "Windowed loading" is therefore not free: `--topo-order` must see the whole DAG before
it can emit the first row correctly. The commit-graph is what makes this affordable, because its
generation numbers let the sort skip work. **#0015 must not assume a window bounds the load cost.**

**3. Lane assignment, not loading, is the scaling problem beyond a few thousand rows.** 2.1 s at
20,000 commits. That number is the *spike's naive algorithm* — O(n × lanes) linear scans, and it
leaks lanes badly (4,145 open lanes for 20,000 commits, which a real implementation would compact).
It is not evidence about the shipping algorithm, only that #0015's algorithm choice matters more
than its data source. Treat 2.1 s as an upper bound to beat, not a prediction.

### Consequence

For a live UI the relevant number is the visible window — on the order of 100 rows — which is
**79 ms via plumbing with a commit-graph**. That is comfortably interactive, and it is the
configuration the app should always be in: Switchyard keeps the commit-graph fresh in the
background, as the guide already proposed.

**This settles the #0004 architecture fork in favour of option 1.** Plumbing was already required
for reftable correctness; it is also 5× faster on the graph path. Option 2 (vendoring libgit2 from
`main`) would buy reftable support and still be ~5× slower here unless it also gained commit-graph
use, so the packaging cost buys nothing on this path. libgit2 stays a candidate only for the object
database, diff, blame, and merge — where neither reftable nor the commit-graph applies.
