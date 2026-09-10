# SHA-256 repositories — a decision prepared for Brennan

Prepared 2026-09-10 (issue #0308, round 1). **This document recommends; Brennan decides.**
Module docs, milestone M5. This round changed no code; everything below was measured against
git 2.50.1 (Apple Git-155) on a real fixture repository.

## The question

Does Switchyard support SHA-256 repositories? Until now the answer differed by file:
`SignatureVerification` recognises the `gpgsig-sha256` header (`SignatureVerification.swift:164`)
while `RevListParser` rejects a 64-character oid (`LaneAssignment.swift:158`) — so `verify` worked
and `graph` threw, on the same repository. **Accidentally half-supported is the one state the issue
rules out.**

## How this was measured

- Fixtures: `build/sha256-probe/sha256` (`git init --object-format=sha256`, two commits, one
  untracked file) and `build/sha256-probe/sha1` as the control, identical history.
- Probe: the built `yard-engine` development harness (the engine linked in-process — the same
  `runEngineCommand` the CLI resolves) run from inside each fixture; exit code and envelope read
  directly. The mutating probe staged a real edit to `file.txt` first.
- Raw git used where the engine never reaches (blame's uncommitted sentinel).

## The measured table — extends the issue's two rows

| command | SHA-256 | SHA-1 | why |
|---|---|---|---|
| `whereami` | works (exit 0) | works | 64-hex `rawHead` carried through; `headOID` is `git rev-parse --short=7`, git's own short form |
| `status` | works | works | porcelain v2 parse, no oid length involved |
| `log` | works | works | 64-hex oids carried verbatim in the payload |
| `graph` | **throws — exit 6 `repository_error`: "malformed rev-list line: \<64-hex\> \<64-hex\>"** | works | `LaneAssignment.swift:158` `token.count == 40` |
| `graph --limit 2` | same refusal | works | same check |
| `verify HEAD` | works (unsigned commit → `noSignature`) | works | unsigned fixture — the `gpgsig-sha256` row stays parser-level evidence (#0306) |
| `conflicts` | works | works | |
| `hunks --staged` | works | works | |
| `wt list` | works (64-hex `head` field) | works | |
| `wt where` | works | works | |
| `rerere status` | works | works | |
| `absorb --dry-run` (staged edit) | **throws — exit 4 `request_failed`: "malformed blame entry header: \<64-hex\> 2 2 1"** | works | `Blame.swift:192` `tokens[0].count == 40` |
| `reword HEAD --message …` | **works** — the full rewrite flow (journal checkpoint, cherry-pick machinery, ref moves) produced a 64-hex head | works | `drop`/`reorder` share this machinery; not individually probed |

**Measured conclusion: exactly two commands break — `graph` and `absorb` — one parser length
check each. Every other engine command measured, including the mutating core, works untouched.**

Also measured with raw git: `git blame --porcelain` prints **64 zeros** for an uncommitted line
under SHA-256 (40 under SHA-1). So `BlameLine.uncommittedOID` (`Blame.swift:14`, 40 zeros) and the
`isUncommitted` derivation (`Blame.swift:59`) are format-dependent *regardless of the parse
checks* — on a SHA-256 repository an uncommitted line can never match the constant.

Not measured: signed commits (the probe has no signing key — `verify`'s SHA-256 evidence is the
parser-level `gpgsig-sha256` recognition, as the issue already recorded); `split`, `drop`,
`reorder` individually (they share `reword`'s machinery, which measured clean); the app target.

## The audit — `grep -n "40" YardKit/Sources/YardGit/*.swift`

29 hits. **Three sites assume a 40-character oid, one check is tolerant by design, and the other
25 are prose, issue numbers, or git file modes.**

| hit | classification |
|---|---|
| `Blame.swift:14` — `uncommittedOID = String(repeating: "0", count: 40)` | **oid-length assumption** — the uncommitted sentinel; measured 64 zeros under SHA-256, so `isUncommitted` can never fire |
| `Blame.swift:192` — `tokens[0].count == 40` | **oid-length check** — measured breakage (`absorb` → blame throws) |
| `LaneAssignment.swift:158` — `token.count == 40 && hex` | **oid-length check** — measured breakage (`graph` throws) |
| `Rerere.swift:219` — `name.count >= 40 && hex` | oid-length check, **tolerant by design** — `>=` accepts 64; documented as such at 185–186 and 212 |
| `Blame.swift:13` | prose — documents the sentinel |
| `Blame.swift:185` | prose — documents the 192 check |
| `Blame.swift:278` | prose — documents the sentinel reaching the wire (#0129 Decision 7) |
| `CommitLog.swift:248` | prose — describes the format string; no length check in code (log measured working on 64-hex) |
| `Hunks.swift:528`, `534`, `640`, `656` | prose — `--full-index` rationale; no length check |
| `JournalAnchor.swift:291`, `297`, `300` | **not oid** — `040000` is git's directory file mode |
| `LaneAssignment.swift:131`, `139` | prose — documents the 158 check |
| `PostRewrite.swift:56` | prose — states both formats; parser checks field counts only (verified) |
| `ReferenceTransaction.swift:52`, `56` | prose — parser and `isAllZeros` are length-agnostic (verified) |
| `Rerere.swift:30` | prose |
| `Rerere.swift:185`, `186`, `212` | prose — documents the tolerant check |
| `Staging.swift:1`, `100`, `236` | **not oid** — issue numbers `#0040`, `#0140` |
| `WhereAmI.swift:143` | **not oid** — issue number `#0140` |
| `WorktreeDisturbance.swift:230` | prose — the code reads branch names, no length check |

### Beyond the grep

- `RewriteDiff.swift:43` spells the SHA-1 empty tree as a constant — **dead code**: the only use
  site (line 403) calls `emptyTreeOID(at:git:extraEnvironment:)`, which materialises the empty
  tree with `git mktree` in the repository's own format. Object-format-agnostic by construction.
- `ReferenceTransaction` parse and `PostRewrite` parse: no oid length checks (verified by reading
  the guards — field counts and non-emptiness only).
- `FixtureRepository` passes `--ref-format` but never `--object-format` — **every test fixture is
  SHA-1 today**, so nothing in the suite exercises the 64-hex paths.

## The three defensible answers

### A. Support SHA-256 now

Measured cost:

1. `LaneAssignment.swift:158` and `Blame.swift:192`: relax `count == 40` to accept 40 or 64 (or any
   hex of either length). Small, mechanical, testable.
2. `Blame.swift:14`/`59`: `uncommittedOID` must become length-agnostic — an all-zeros comparison
   like `ReferenceTransaction.isAllZeros`. **This is the real cost**: the constant is public,
   #0129 Decision 7 has readers derive `isUncommitted` from it, the wire carries `oid` verbatim,
   and the wire tests pin the encoded bytes. A public-contract change, not a private parse fix.
3. `FixtureRepository` gains an object-format parameter; graph/log/blame/absorb tests gain SHA-256
   variants. A recurring tax: every future parser test inherits it.
4. Residue: the mutating commands beyond `reword` and the app target stay audited-clean, not
   measured-clean, until someone probes them.

### B. Out of scope, with a structured refusal

The failure stops lying. Today an agent hitting `graph` on a SHA-256 repo reads
`malformed rev-list line:` — a false claim that git's output was bad, when the truth is that the
repository's hash algorithm is unsupported (M1 criterion 3's territory). The change, exactly:

- **Detection**: one `git rev-parse --show-object-format` at the entry of the two measured broken
  flows — `graphRows` (LaneAssignment.swift) and the absorb flow before `blameFile` (Absorb.swift /
  Blame.swift). The repository's format is fixed at init, so per-flow detection at these two
  entries is enough; a global gate in `WorktreeContext` would refuse the ten commands measured
  working.
- **Error shape**: one refusal case on the existing failure enums (e.g.
  `RevListParser.Failure.unsupportedObjectFormat("sha256")`, and the blame-side equivalent),
  message naming the algorithm. Exit classes follow the surfaces' existing mappings as measured:
  graph → 6 `repository_error`; absorb currently reports 4 `request_failed` for blame parse
  failures, which the follow-up keeps or corrects — its call, one sentence.
- **Tests**: `Tests/YardGitTests/LaneAssignmentTests.swift` and `BlameTests.swift` gain a 64-hex
  input row asserting the refusal names the algorithm, not `malformedLine`/`malformedEntryHeader`.
- **Cost**: one detection point, one failure case per flow, two test rows. No wire-schema change
  measured or expected.

### C. Defer to a named milestone

M5 is where the issue already parks it. Deferring means no change now and the audit refiled as an
M5 issue — but it also keeps the works-throws split live through M2–M4, and `graph` keeps lying
(`malformedLine`) to every agent that hits it in the meantime. The refusal of answer B is smaller
than the deferral's cost of carrying the lie.

## Recommendation — B: out of scope, refuse cleanly

**This is a recommendation for Brennan, not a settlement.** Reasoning:

- No user demand for SHA-256 is on record, and git's default is SHA-1 — a SHA-256 repository
  exists only because someone passed `--object-format=sha256` at init.
- The measured breakage is two parser checks; everything else works. The refusal is small, local,
  and removes the only incoherence.
- Support-now's decisive cost is a public wire-contract change (`uncommittedOID`) with nothing
  driving it; deferral keeps the incoherence live for three milestones.

**Reversal triggers** — re-open this decision if any of these happens:

- A user or interop requirement names SHA-256 repositories explicitly.
- git changes `init`'s default object format.
- A feature in flight turns out to require SHA-256 before the refusal would ship.
- The refusal change grows past one detection point, two failure cases, and two test rows — that
  would mean the small change this recommendation rests on was mis-sized.
