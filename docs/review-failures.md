# Review failures — what went wrong, and the check that prevents a repeat

Every dispatch round that failed review, with its root cause and the preflight check derived from it.
**Read the checklist before dispatching; add to it the moment a round fails.** The protocol that
governs this file is in `CLAUDE.md` § "Learning from failed reviews".

The point of this file is not history. It is the checklist in the second half — the table exists to
justify the checks and to stop them being quietly dropped as superstition.

A note on the pattern: most failures here are `spec-defect`. The local model has generally done what
it was told; the losses came from telling it something wrong, something impossible in its sandbox, or
too many things at once. **Assume a failed round is an authoring defect until the evidence says
otherwise.**

## Failure log

| Issue | Round | Symptom | Root cause | Class |
|---|---|---|---|---|
| #0070 | 1 | Round produced a fluent, well-argued document; accepted on review | The document asserted three false things about git trailers (`%trailers` as a format atom, case-sensitive matching, silence on the final-paragraph constraint that voids the whole block). The model *had* run real commands — the errors were in its interpretation. I reviewed by reading, agreed, and marked it resolved. Caught only by a later adversarial re-check. | `review-defect` |
| #0070 | 2 | Round died partway; incomplete work | Two causes compounded. OpenCode auto-rejected a write to `/tmp`. And my review feedback had asked the model to *verify* several git facts — turning a bounded implementation task into open-ended research, which is the shape the model handles worst. | `environment` + `review-defect` |
| #0085 | 1 | Correct code, tests passing, but the file landed at a different path than specified, and `issues/0085.md` had been edited | The issue specified `YardKit/Sources/yard/CommandSpec.swift`. `yard` is a SwiftPM `executableTarget`, so `@testable import yard` does not link — the issue was unbuildable as written. The model diagnosed it correctly and relocated the file to the library target, which was right, but then rewrote the issue text to match its own deviation instead of stopping to report the block. | `spec-defect` (+ `model-behaviour`) |
| #0098 | 1 | Harness exit 7 — "no changes"; 81s; nothing produced | The issue never said where the 1024×1024 intermediate should go, so the model chose `/var/tmp`, which OpenCode auto-rejects (`permission requested: external_directory (/var/tmp/*); auto-rejecting`). It then wrote *"Now I have a clear picture. Let me execute the steps"* and ended its turn without executing any of them. | `environment` + `model-behaviour` |
| #0010, #0011, #0022 | — | Repeatedly failed to converge before being split | Each bundled four deliverables. No issue with more than one deliverable has converged in this project; every issue that has converged named exactly one file. | `sizing` |

## Preflight checklist

Run before every dispatch, including re-dispatches. `[MECHANICAL]` checks are implemented in
`scripts/preflight-issue.sh` and enforced by `dispatch-issue.sh`; `[JUDGMENT]` checks require reading
the issue.

### Mechanical — the script decides

1. **`[MECHANICAL]` Does the issue name a file inside an executable target?**
   Nothing there can be unit-tested. Derived from #0085.
2. **`[MECHANICAL]` Does the issue reference `/tmp`, `/var/tmp`, or any absolute path outside the
   worktree?** The sandbox auto-rejects those writes. Derived from #0070 r2 and #0098 r1.
3. **`[MECHANICAL]` Does the issue name at least one concrete file path?**
   Every converged issue named a file; every issue that failed to converge named none.
4. **`[MECHANICAL]` Does the issue tell the model to verify a fact, check current usage, or run
   `--help` instead of stating the fact?** Open-ended verification is the shape the model handles
   worst. Derived from #0070 r2. State verified facts as givens.

### Judgment — read the issue and answer honestly

5. **`[JUDGMENT]` Is there exactly one deliverable?** Not "one theme" — one file, one behaviour, one
   thing that is either done or not. If the Expected behavior list describes two things that could
   land independently, split it. Derived from #0010/#0011/#0022.
6. **`[JUDGMENT]` Was every fact the issue asserts actually verified, by me, in this repo?**
   Not recalled, not inferred from a man page. Derived from #0070 r1.
7. **`[JUDGMENT]` If the task integrates a tool's output, have I run that tool and written down what
   it actually produced?** `--help` documents the interface; only execution reveals the output shape,
   and the integration depends on the shape. #0098's `icongen` emits `AppIcon-macOS.appiconset` while
   Xcode expects `AppIcon` — a fact absent from its help text, which would have silently produced an
   icon set Xcode ignores.
8. **`[JUDGMENT]` Can the named path hold a unit test?** A path is a claim about the build system and
   it can be wrong. Check it against `Package.swift`, not against intuition. Derived from #0085.
9. **`[JUDGMENT]` Does completing this require any write outside the worktree?** If so, name a
   `build/`-relative path in the issue explicitly. Derived from #0098.

## Already covered — do not add duplicate guards

| Failure mode | Existing guard |
|---|---|
| Dispatching from the wrong branch | `dispatch-issue.sh` branch check, exit 8 |
| A round's diff not attributable to it | `dispatch-issue.sh` clean-tree check, exit 4 |
| Looping forever on a task that will not converge | `dispatch-issue.sh` 3-round cap, exit 3 |
| A run hanging indefinitely | `dispatch-issue.sh` wall-clock timeout |
| A file named in an executable target | `dispatch-issue.sh` preflight, exit 9 |
| Copying GPL source from GitUp | `AGENTS.md` Rule 1 |
| Touching Apple signing assets | `AGENTS.md` Rule 2 |
| Claiming verification that did not happen | `AGENTS.md` Rule 3 |
| Committing, branching, or resolving | `AGENTS.md` Rule 4 |
| Retrying instead of stopping | `AGENTS.md` Rule 5 |
| Writing scratch files outside the worktree | `AGENTS.md` Rule 6 |
