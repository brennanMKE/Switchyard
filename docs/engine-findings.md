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

### Confirmed by direct experiment, 2026-08-06

Prompted by Brennan noticing that `Switchyard.xcodeproj` referenced nothing from `YardKit`, the
integration was tested on a scratchpad **copy** of the project — the real one was open in Xcode, and
Xcode rewrites `project.pbxproj` underneath edits.

`YardKit` and `YardGit` were added as an `XCLocalSwiftPackageReference` with both products as
`XCSwiftPackageProductDependency`, and `ContentView` was made to reference a real symbol from each so
that linking was exercised rather than merely declared.

**Result: `** BUILD SUCCEEDED **`, and the integration is genuinely real.** Verified on the built
product rather than trusting the build result — note that under Xcode 26 the app's `MacOS/Switchyard`
is a thin stub and the code lives in `Switchyard.debug.dylib`, so checking the wrong file shows
nothing:

```
otool -L Switchyard.debug.dylib
    /opt/homebrew/opt/libgit2/lib/libgit2.1.9.dylib (current version 1.9.6)
nm -u  → _git_libgit2_init, _git_libgit2_shutdown, _git_libgit2_version
nm     → YardKit, YardGit symbols present
```

**So an Xcode app target does build and link against a SwiftPM package whose chain includes a
`systemLibrary` target resolved by Homebrew `pkgConfig`.** That was an open assumption underneath
every issue written so far, and it holds.

**And it fails to ship, exactly as predicted, now with the mechanism visible.** The load command is
the absolute path `/opt/homebrew/opt/libgit2/lib/libgit2.1.9.dylib`. An app distributed with that
load command runs only on a machine with Homebrew libgit2 installed at that precise path — which is
no user's machine. It is not a link-time failure that CI would catch; it is a launch-time failure on
someone else's Mac.

This affects the **app target as well as the embedded CLI**. #0050 covers embedding `switchyard` in
the bundle; nothing yet covers replacing the Homebrew `systemLibrary` with a vendored binary for the
app itself. Filed as #0103.

**Unresolved for route A:** Homebrew installs per-architecture into `/opt/homebrew` (Apple Silicon)
or `/usr/local` (Intel), and a distributed app cannot depend on a user's Homebrew. This route is
viable for development but **not for shipping**, since the embedded `yard` (#0050) must run on a
machine with no Homebrew at all.

### libgit2 needs no transport at all — measured 2026-08-06

`git_libgit2_features()` on the current Homebrew build reports `HTTPS yes, SSH yes`. Those two
options are the entire reason the dependency tree includes OpenSSL and libssh2; with
`-DUSE_SSH=OFF -DUSE_HTTPS=OFF` the vendoring problem collapses from five libraries to one.

Nothing is lost, because network operations were never going to use libgit2. `CLAUDE.md` already
requires shelling out to `git` for hooks, network operations, and signing, centralised in
`GitProcess`. That is the stronger choice on its own merits: `git` already resolves the user's SSH
agent, `credential.helper`, Keychain, `.netrc`, `insteadOf` rewrites, proxies and 2FA tokens.
libgit2's transport would mean implementing credential callbacks that reproduce a *subset* of that,
and any divergence appears to the user as "works in my terminal, fails in the app".

libgit2 keeps every local operation — objects, refs, index, diff, merge, traversal — which is where
per-query process spawning would be unaffordable and where the commit-graph measurements above apply.
The `git_remote_*` family becomes unusable; note that ahead/behind for `yard whereami` reads
`refs/remotes/` locally and needs no network, so the highest-traffic command is unaffected.

Acceptance for the vendored build is the probe, not the build log: HTTPS off, SSH off, THREADS on.

### Route B has a known-good shape — GitUp's, checked 2026-08-06

GitUp vendors **static** libraries inside universal `.xcframework`s, built from source with CMake by
`rebuild-*.sh` scripts, with the built artefacts committed:
`GitUpKit/Third-Party/libgit2.xcframework/macos-arm64_x86_64/libgit2.a`, plus the same treatment for
`libssh2`, `libssl`, `libcrypto` and `libsqlite3`, tracked against a maintained fork.

Static is the important part. A static `.a` cannot fail at launch on a machine that lacks a dylib,
because there is no dylib — the failure mode disappears rather than being relocated into
`Contents/Frameworks/` where it needs embedding, `@rpath` handling and separate signing.

That GitUp also vendors libssh2 and OpenSSL confirms the transitive problem measured here: Homebrew's
`libgit2.1.9.dylib` is itself linked against `/opt/homebrew/opt/llhttp/…` and
`/opt/homebrew/opt/libssh2/…` by absolute path, so "copy the dylib into the bundle" is really "copy a
dependency tree and rewrite every load command in it".

**Licensing:** libgit2 is GPLv2 **with a linking exception** granting unlimited permission to link the
compiled library into other programs and distribute the combination without restriction. MIT
Switchyard may link and ship it. Modifying libgit2 itself would put those changes under GPLv2, so pin
unmodified upstream. This is separate from the GitUp clean-room rule — GitUp's own source is off
limits; libgit2 is a third-party dependency both projects consume. Their rebuild scripts are GPLv3;
read them for shape, write ours.

### Route B: vendored / prebuilt — the shipping route, not yet built

libgit2 builds with CMake, which SwiftPM cannot drive directly, so this means building libgit2
separately and consuming a prebuilt `xcframework` as a `binaryTarget`. **This is what shipping
requires**, since route A depends on the user's Homebrew and the embedded `yard` (#0050) must run on
a machine that has none.

It is also the only route that could unlock reftable in-process, by building from `main`. #0003's
numbers say that is not worth doing for the graph path — plumbing is faster there regardless — so
route B's job is narrower than it first appeared: package libgit2 for the object database, diff,
blame, and merge, and let refs and traversal go through plumbing.

Deferred to whichever issue actually needs libgit2 in the bundle. Nothing in M1 does.

### Route C: existing Swift bindings — both rejected

Checked 2026-08-06:

| Binding | Last push | Latest tag | Verdict |
|---|---|---|---|
| [SwiftGit2](https://github.com/SwiftGit2/SwiftGit2) | 2025-11-24 | `v0.3` | Maintained but pre-1.0, 50 open issues, and a thin wrapper we would still be working around. |
| [objective-git](https://github.com/libgit2/objective-git) | 2023-09-17 | `0.14.2` | **~3 years stale.** Not a dependency to take on in 2026. |

Neither is worth the coupling. The `systemLibrary`/`binaryTarget` route gives direct C access with no
intermediary, and the subset of libgit2 Switchyard needs is small by design (guide §1 non-goals).

**`gitoxide` remains a live alternative** — pushed the same day this was checked, so unlike the Swift
bindings it is actively developed. It stays the documented fallback if libgit2 packaging proves
unworkable in route B, with the FFI and build complexity noted in the guide still applying.

### Route A verdict

**Development only.** Good enough to build and test against, and it is what the M0 spike used. It
cannot ship, because a distributed app cannot depend on a user's Homebrew. Whatever ships must be
self-contained inside the bundle — that is route B's job.

---

## #0002 — SSH-signed commits through libgit2

### Answer: yes, locally verified. One criterion outstanding, and it needs Brennan.

The three-step shape from guide §5 works exactly as described. Against a throwaway repo and a
throwaway ed25519 key in a temp directory — the user's real git config and `~/.ssh` untouched:

```
[PASS] generate throwaway ed25519 key
[PASS] git_commit_create_buffer — 209 bytes
[PASS] ssh-keygen -Y sign — 294 bytes
[PASS] git_commit_create_with_signature — 0a59a4d571
[PASS] git log --show-signature reports Good —
       Good "git" signature for spike@test with ED25519 key SHA256:DYZTl5JaDhb…
[PASS] ssh-keygen -Y verify round trip — verified
[PASS] commit object carries gpgsig header — present
ALL PROBES PASSED
```

So: build content with `git_commit_create_buffer`, sign that buffer with
`ssh-keygen -Y sign -f <key> -n git`, attach with `git_commit_create_with_signature` under header
field `gpgsig`. git reads the result as a good signature. libgit2 never produces the signature, only
attaches it, exactly as the guide anticipated.

Findings worth carrying into #0036:

- **`gpg.ssh.allowedSignersFile` is not optional for verification.** Without it git reports the
  signature as untrusted rather than good — the signature is valid, but git has no basis to trust the
  key. `yard verify` (#0019) must distinguish "no signature", "signature present but signer not
  allowed", and "good signature", which is three states, not two.
- **The signed commit must be written and then `HEAD` moved to it.** `git_commit_create_with_signature`
  writes the object but updates no reference, so the caller owns the ref update. That is a journal
  concern (#0027): the ref move is the part that needs a snapshot, not the object write.
- **libgit2 reads and writes the same `gpgsig` header for SSH as for GPG.** No separate field, so
  format detection is by signature content, not header name.

### Outstanding: GitHub verification

The issue also requires that GitHub reports such a commit as verified. That needs a push to a
scratch repository under Brennan's account and an SSH signing key registered on it, which is an
outward action on his account. **Not done — needs Brennan.** Everything verifiable locally passes.

This does not block M1: the local result establishes the mechanism, and GitHub's verification is a
policy check on key registration rather than a property of the commit we produce.

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
