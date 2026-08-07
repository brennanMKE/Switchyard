# Cost ledger

Measured token counts from this project's dispatcher subagents, captured as they were reported.

**Why this file exists.** These figures are reported once, in a completion notification, and exist
nowhere else — not in git, not in a log, not in any API. When a session ends they are gone. Anything
not written down here at the moment it was measured is unrecoverable.

**Rate:** Claude Opus 5 — $5.00 per million input tokens, $25.00 per million output.
`subagent_tokens` is a combined figure with no input/output split, so cost is computed at an assumed
**85% input / 15% output** = **$8.00 per million combined tokens**. The assumption is stated wherever
a figure derived from it appears.

**Local implementation via Ornith/LM Studio is $0.00** at any volume and is not listed here.

## Measured dispatcher subagent runs

| Date | Issue | Subagent purpose | Tokens (measured) | Cost @ $8/MTok |
|---|---|---|---:|---:|
| 2026-08-06 | #0070 | Dispatch round 1 (initial run) | 35,523 | $0.28 |
| 2026-08-06 | #0070 | Dispatch round 1 (resumed after early return) | 49,526 | $0.40 |
| 2026-08-06 | #0070 | Dispatch round 2 (sandbox-blocked, no output) | 33,338 | $0.27 |
| 2026-08-06 | #0070 | Dispatch round 3 (converged) | 54,035 | $0.43 |
| 2026-08-06 | #0011 | Dispatch round 1 (rejected — exit codes swapped) | 50,281 | $0.40 |
| 2026-08-06 | #0011 | Dispatch round 2 (rejected — stdout contract still broken) | 44,269 | $0.35 |
| 2026-08-06 | #0010 | Dispatch round 1 (timed out, broken build) | 49,698 | $0.40 |
| 2026-08-06 | #0085 | Dispatch round 1 (correct code, spec defect found) | 47,061 | $0.38 |
| 2026-08-06 | #0001–#0005 | Work-log format conversion | 28,417 | $0.23 |
| 2026-08-06 | #0006–#0009 | Work-log format conversion | 25,992 | $0.21 |
| 2026-08-06 | #0024 | Work-log format conversion | 19,096 | $0.15 |
| 2026-08-06 | #0098 | Dispatch round 1 (failed: sandbox denial, exit 7) | 45,120 | $0.36 |
| 2026-08-06 | #0098 | Dispatch round 2 (converged, 190s) | 55,326 | $0.44 |
| 2026-08-06 | #0090 | Dispatch round 1 (REJECTED, 1289s) | 50,649 | $0.41 |
| 2026-08-06 | #0090 | Dispatch round 2 (accepted, 139s) | 45,920 | $0.37 |
| 2026-08-06 | #0090 | Failure post-mortem subagent | 77,282 | $0.62 |
| 2026-08-06 | — | Cross-cutting post-mortem over all failed rounds | 134,166 | $1.07 |
| 2026-08-06 | #0086 | Dispatch round 1 (REJECTED, 125s) | 47,974 | $0.38 |
| 2026-08-06 | #0086 | Dispatch round 2 (accepted, 302s) | 60,608 | $0.48 |
| 2026-08-06 | #0091 | Dispatch round 1 (accepted, 782s) | 62,046 | $0.50 |
| 2026-08-06 | #0087 | Dispatch round 1 (REJECTED, 856s) | 124,876 | $1.00 |
| | | **Total measured** | **1,141,203** | **$9.13** |

## What this total does and does not cover

**Covers:** every dispatcher subagent spawned during the project — the review and verification layer
around delegated rounds, plus the work-log maintenance runs.

**Does not cover:** main-loop authoring and review (issue writing, diff review, doc work, merges).
This harness reports no per-turn usage, and with no `ANTHROPIC_API_KEY` and no `ant` CLI on this
machine there is no `count_tokens` call available either. **That spend is real and is larger than the
figure above** — it is simply not measurable from inside a session. #0089 tracks closing the gap.

## The economics so far, stated honestly

**$3.48 measured on dispatch and review. $0.00 on implementation — for one issue.** #0070 is the only
issue Ornith has implemented end to end, and it took three rounds, of which one produced nothing.
#0010 and #0011 were rejected and re-dispatched.

So the delegation has not yet paid for itself: review cost is currently higher than the
implementation cost it replaces. That is expected this early — the review discipline caught a swapped
exit-code contract and three false claims about git that would otherwise have shipped — but it should
be revisited once several M1 issues have gone through cleanly, and the `Rounds` column is the number
to watch.

## Recording rule

**Write a measurement down in the same turn it is reported.** A number held only in conversation
context is already lost.
