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
| 2026-08-06 | #0092 | Dispatch round 1 (accepted, 437s) | 50,143 | $0.40 |
| 2026-08-06 | #0087 | Dispatch round 2 (accepted, 1548s) | 80,048 | $0.64 |
| 2026-08-06 | #0093 | Dispatch round 1 (REJECTED, timed out at 1800s) | 60,714 | $0.49 |
| | | **Total measured** | **1,332,108** | **$10.66** |

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

## Ornith — what the local model has processed

Regenerate with `./scripts/ornith-tally.sh` (add `--markdown` for this table). The numbers come from
OpenCode's own SQLite database at `~/.local/share/opencode/opencode.db`, which records
`tokens_input` and `tokens_output` per session. **The dispatch logs carry no token counts at all**,
and LM Studio exposes no historical usage endpoint — this database is the only durable record, and
unlike a dispatcher's `subagent_tokens` it survives the session that produced it. Issues are
attributed by the session's working directory, since a dispatch runs in `../switchyard-NNNN`.

| Issue | Sessions | Input tokens | Output tokens | Total | Hosted equivalent |
|---|---|---|---|---|---|
| (main) | 6 | 3,090,068 | 17,302 | 3,107,370 | $9.53 |
| #0010 | 1 | 3,599,879 | 24,832 | 3,624,711 | $11.17 |
| #0011 | 1 | 2,409,020 | 22,566 | 2,431,586 | $7.57 |
| #0070 | 3 | 830,633 | 6,347 | 836,980 | $2.59 |
| #0085 | 1 | 429,505 | 3,543 | 433,048 | $1.34 |
| #0086 | 2 | 701,247 | 5,498 | 706,745 | $2.19 |
| #0087 | 3 | 2,789,837 | 41,131 | 2,830,968 | $8.99 |
| #0090 | 2 | 1,961,394 | 35,115 | 1,996,509 | $6.41 |
| #0091 | 1 | 952,760 | 8,181 | 960,941 | $2.98 |
| #0092 | 1 | 1,605,158 | 8,955 | 1,614,113 | $4.95 |
| #0093 | 1 | 3,588,422 | 27,867 | 3,616,289 | $11.18 |
| #0098 | 2 | 423,236 | 2,340 | 425,576 | $1.30 |
| #0102 | 1 | 3,031,848 | 12,401 | 3,044,249 | $9.28 |
| **Total** | **25** | **25,413,007** | **216,078** | **25,629,085** | **$79.48** |

Actual cost: **$0.00**. Ornith runs locally in LM Studio; the hosted column is what the
same traffic would have cost on Sonnet 5 at list price ($3/MTok in, $15/MTok out), which is
the model CLAUDE.md says it replaces.

### What the numbers say

**Input outweighs output by roughly 118 to 1.** That is the shape of an agentic loop, not a
peculiarity of this model: every turn resends the accumulated context, so a thirty-minute round
re-reads its own transcript hundreds of times. It is the single strongest argument for running the
implementer locally — on a hosted model this ratio is the whole bill, and here it is free.

**The most expensive rounds are the ones that failed.** #0093 processed 3.6M tokens and was killed at
the timeout having produced nothing usable; #0010 processed 3.6M before being split for being
oversized; #0087 spent 2.8M across three sessions, two of them chasing a test that asserted nothing.
Roughly **13.7M of the 25.6M — over half — went on rounds that were rejected or abandoned.** That is
the cost of authoring defects, and it is invisible in the dollar column precisely because it is free.

**`(main)` is 3.1M tokens of sessions that predate the worktree rule.** They ran in the primary
checkout, which is exactly what `CLAUDE.md` now forbids.
