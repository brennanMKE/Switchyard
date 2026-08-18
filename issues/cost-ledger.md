# Cost ledger

Measured token counts from this project's dispatcher subagents, captured as they were reported.

**Why this file exists.** These figures are reported once, in a completion notification, and exist
nowhere else — not in git, not in a log, not in any API. When a session ends they are gone. Anything
not written down here at the moment it was measured is unrecoverable.

**Rate:** Claude Opus 5 — $5.00 per million input tokens, $25.00 per million output.
`subagent_tokens` is a combined figure with no input/output split, so cost is computed at an assumed
**85% input / 15% output** = **$8.00 per million combined tokens**. The assumption is stated wherever
a figure derived from it appears.

**Planning moved to Opus 5 on 2026-08-09** (Brennan's instruction), so planning rows now bill at
the Opus rate above and carry `(O)`. Rows marked `(F)` predate the change. **Implementation rounds
from 2026-08-17 carry `(S)`** — Sonnet at $3/$15 per million, the same 85/15 split, so **$4.80 per
million combined**. They are measured, not estimated: a subagent reports its token count once, in a
completion notification that exists nowhere else.

**Fable 5**, used for planning until then, billed at $10.00 per million input and $50.00 per million output; the
same 85/15 assumption gives **$16.00 per million combined tokens**. Rows using it are marked `(F)`.

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
| 2026-08-06 | #0102 | Dispatch round 1 (REJECTED, 1044s) | 114,261 | $0.91 |
| 2026-08-06 | #0102 | Dispatch round 2 (REJECTED, 132s) | 58,603 | $0.47 |
| 2026-08-06 | #0102 | Dispatch round 3 (95%, finished by hand) | 58,121 | $0.46 |
| 2026-08-06 | #0093 | Dispatch round 2 (accepted, 686s) | 50,650 | $0.41 |
| 2026-08-06 | #0104 | Dispatch round 1 (accepted, 648s) | 47,260 | $0.38 |
| 2026-08-06 | #0099 | Dispatch round 1 (accepted, 1044s) | 41,981 | $0.34 |
| 2026-08-06 | #0100 | Dispatch round 1 (accepted, 471s) | 42,344 | $0.34 |
| 2026-08-06 | #0094 | Dispatch round 1 (accepted, 1019s) | 56,551 | $0.45 |
| 2026-08-06 | #0012 | Dispatch round 1 (REJECTED, timed out at 1800s) | 37,875 | $0.30 |
| 2026-08-07 | #0020 | Dispatch round 1 (REJECTED, timed out at 1800s) | 54,972 | $0.44 |
| 2026-08-07 | #0012 | Dispatch round 2 (REJECTED, timed out at 1800s) | 72,322 | $0.58 |
| 2026-08-07 | #0012 | Dispatch round 3 (accepted, 504s) | 51,411 | $0.41 |
| 2026-08-07 | #0020 | Dispatch round 2 (REJECTED, red suite) | 62,080 | $0.50 |
| 2026-08-07 | #0020 | Dispatch round 3 (accepted, 246s) | 52,087 | $0.42 |
| 2026-08-07 | #0013 | Dispatch round 1 (no output, truncated write) | 48,408 | $0.39 |
| 2026-08-07 | #0014 | Dispatch round 1 (no output, truncated write) | 45,134 | $0.36 |
| 2026-08-07 | #0014 | Dispatch round 2 (timed out, placeholder bodies) | 44,477 | $0.36 |
| 2026-08-07 | #0113 | Dispatch round 1 (sandbox rejection, no output) | 41,137 | $0.33 |
| 2026-08-07 | #0113 | Dispatch round 2 (REJECTED, red suite) | 51,226 | $0.41 |
| 2026-08-07 | #0014 | Round 3 dispatch blocked by unmerged review | 44,255 | $0.35 |
| 2026-08-07 | #0113 | Dispatch round 3 + hand finish (accepted) | 52,198 | $0.42 |
| 2026-08-07 | #0014 | Dispatch round 3 (REJECTED, review defect) | 59,498 | $0.48 |
| 2026-08-07 | #0107 | Dispatch round 1 (accepted, 176s) | 37,723 | $0.30 |
| 2026-08-07 | #0111 | Dispatch round 1 (REJECTED, fabricated comments) | 38,174 | $0.31 |
| 2026-08-07 | #0014 | Dispatch round 4 + hand finish (accepted) | 64,602 | $0.52 |
| 2026-08-07 | #0111 | Dispatch round 2 + hand finish (accepted) | 42,137 | $0.34 |
| 2026-08-07 | #0106 | Dispatch round 1 (REJECTED, unfalsifiable assertions) | 38,807 | $0.31 |
| 2026-08-07 | #0106 | Dispatch round 2 + hand finish (accepted) | 41,050 | $0.33 |
| 2026-08-07 | #0105 | Dispatch round 1 + hand finish (accepted) | 44,917 | $0.36 |
| 2026-08-07 | #0112 | Dispatch round 1 (REJECTED, unrunnable mutations) | 40,053 | $0.32 |
| 2026-08-07 | #0095 | Dispatch round 1 (REJECTED, tests never compiled) | 57,216 | $0.46 |
| 2026-08-07 | #0095 | Dispatch round 2 + hand finish (accepted) | 55,081 | $0.44 |
| 2026-08-07 | #0112 | Dispatch round 2 (REJECTED, cherry-pick fixture untouched) | 53,571 | $0.43 |
| 2026-08-07 | #0110 | Dispatch round 1 (accepted) | 53,310 | $0.43 |
| 2026-08-07 | #0112 | Dispatch round 3 (accepted) | 54,826 | $0.44 |
| 2026-08-07 | #0096 | Dispatch round 1 (REJECTED, no tests written) | 50,676 | $0.41 |
| 2026-08-07 | #0088 | Dispatch round 1 (REJECTED, two assertions absent, scope violation) | 62,839 | $0.50 |
| 2026-08-07 | #0096 | Dispatch round 2 (REJECTED, test file does not compile) | 64,158 | $0.51 |
| 2026-08-07 | #0088 | Dispatch round 2 + hand finish (accepted) | 65,420 | $0.52 |
| 2026-08-07 | #0096 | Dispatch round 3 (REJECTED, timeout; cap spent, split to #0120) | 53,429 | $0.43 |
| 2026-08-07 | #0117 | Dispatch round 1 + hand finish (accepted) | 48,971 | $0.39 |
| 2026-08-07 | #0013 | Dispatch round 2 (REJECTED, no tests, fabricated report) | 62,109 | $0.50 |
| 2026-08-07 | #0013 | Dispatch round 3 + hand finish (accepted) | 63,774 | $0.51 |
| 2026-08-07 | #0120 | Dispatch round 1 (FAILED, hung inference, zero output) | 45,710 | $0.37 |
| 2026-08-07 | #0120 | Round-2 guard refusal, no round spent | 39,653 | $0.32 |
| 2026-08-07 | #0120 | Dispatch round 2 + hand finish (accepted) | 62,182 | $0.50 |
| 2026-08-07 | #0114 | Dispatch round 1 (REJECTED, deadlocking test, unbuildable criteria) | 67,757 | $0.54 |
| 2026-08-07 | #0119 | Dispatch round 1 (REJECTED, red suite reported as green) | 59,665 | $0.48 |
| 2026-08-07 | #0114 | Dispatch round 2 + hand finish (accepted) | 59,241 | $0.47 |
| 2026-08-07 | #0119 | Dispatch round 2 + hand finish (accepted) | 60,583 | $0.48 |
| 2026-08-07 | #0121 | Dispatch round 1 (REJECTED, removed a line with two jobs) | 46,854 | $0.37 |
| 2026-08-07 | #0121 | Dispatch round 2 (FAILED, compaction fabricated history) | 50,014 | $0.40 |
| 2026-08-07 | #0116 | Dispatch round 1 (REJECTED, timeout, signatures not supplied) | 59,663 | $0.48 |
| 2026-08-07 | #0118 | Dispatch round 1 (accepted, no hand finish) | 58,213 | $0.47 |
| 2026-08-07 | #0116 | Dispatch round 2 + hand finish (accepted) | 67,812 | $0.54 |
| 2026-08-07 | #0122 | Dispatch round 1 + hand finish (accepted) | 56,208 | $0.45 |
| 2026-08-07 | #0097 | Dispatch round 1 (REJECTED, fixture path never matched git's) | 67,185 | $0.54 |
| 2026-08-07 | #0097 | Dispatch round 2 (REJECTED, found a real production defect) | 65,428 | $0.52 |
| 2026-08-07 | #0097 | Dispatch round 3 + hand finish (accepted) | 49,704 | $0.40 |
| 2026-08-07 | #0123 | Dispatch round 1 (accepted, app-launch fix) | 65,077 | $0.52 |
| 2026-08-07 | #0126 | Dispatch round 1 + hand finish (accepted) | 41,760 | $0.33 |
| 2026-08-07 | #0124 | Dispatch round 1 (FAILED, hung inference, no code) | 44,636 | $0.36 |
| 2026-08-07 | #0124 | Dispatch round 2 (REJECTED, sandbox reject mid-edit) | 43,288 | $0.35 |
| 2026-08-07 | #0124 | Dispatch round 3 (REJECTED, no tests; cap spent) | 61,388 | $0.49 |
| 2026-08-07 | #0108 | Fable planning update to code level | 93,698 | $0.75 |
| 2026-08-07 | #0108 | Dispatch round 1 (ACCEPTED, no hand finish) | 65,164 | $0.52 |
| 2026-08-07 | #0109 | Fable planning update to code level | 94,382 | $0.75 |
| 2026-08-07 | #0109 | Dispatch round 1 + hand finish (accepted) | 72,666 | $0.58 |
| 2026-08-07 | #0017 | Dispatch round 1 — FAILED, no code (context exhaustion) | 48,824 | $0.39 |
| 2026-08-07 | #0127 | Fable planning pass, re-author to code level (F) | 148,904 | $2.38 |
| 2026-08-07 | #0016 | Fable planning pass, re-author to code level + split (F) | 189,586 | $3.03 |
| 2026-08-07 | #0127 | Dispatch round 1 (accepted, one hand-finish line) | 51,082 | $0.41 |
| 2026-08-07 | #0017 | Dispatch round 1 retry on fixed harness (accepted) | 55,219 | $0.44 |
| 2026-08-07 | #0019 | Dispatch round 1 (rejected, incomplete) + failure analysis | 69,807 | $0.56 |
| 2026-08-07 | #0018 | Fable planning pass, re-author to code level (F) | 201,161 | $3.22 |
| 2026-08-07 | #0018 | Dispatch round 1 (accepted, one round) | 56,016 | $0.45 |
| 2026-08-07 | #0019 | Dispatch round 2 (accepted with hand finish) | 70,873 | $0.57 |
| 2026-08-07 | #0015 | Fable planning pass, re-author to code level (F) | 250,956 | $4.02 |
| 2026-08-07 | #0016 | Dispatch round 1 (accepted) + ~25min stranded in await | 58,592 | $0.47 |
| 2026-08-07 | #0015 | Dispatch round 1 (accepted) + stranded-await re-poll | 114,910 | $0.92 |
| 2026-08-07 | #0021/#0023/#0128 | Fable planning pass, three-way split + measure (F) | 303,020 | $4.85 |
| 2026-08-07 | #0025 | Fable planning pass, re-author to code level (F) | 225,068 | $3.60 |
| 2026-08-07 | #0021 | Dispatch round 1 (accepted) | 68,364 | $0.55 |
| 2026-08-07 | #0023 | Dispatch round 1 (accepted) | 73,262 | $0.59 |
| 2026-08-07 | #0026 | Fable planning pass + filed #0129 gap issue (F) | 176,309 | $2.82 |
| 2026-08-07 | #0025 | Dispatch round 1 (accepted) | 65,062 | $0.52 |
| 2026-08-07 | #0026 | Dispatch round 1 (accepted) | 64,950 | $0.52 |
| 2026-08-07 | #0128 | Dispatch round 1 (accepted) | 46,991 | $0.38 |
| 2026-08-07 | #0129 | Fable planning pass + filed #0130-#0136 (F) | 181,156 | $2.90 |
| 2026-08-07 | #0129 | Dispatch round 1 FAILED — no anthropic provider (0 model tokens) | 43,819 | $0.35 |
| 2026-08-07 | #0130 | Fable planning pilot for the wire-encoding family (F) | 125,631 | $2.01 |
| 2026-08-07 | #0131 | Fable planning pilot, Decision 6 verdict (F) | 157,109 | $2.51 |
| 2026-08-07 | #0134 | Fable planning pilot, Decision 5 verdict + filed #0137 (F) | 194,573 | $3.11 |
| 2026-08-07 | #0131 | Dispatch round 1 (accepted) | 56,305 | $0.45 |
| 2026-08-07 | #0130 | Dispatch round 1 (accepted) | 57,397 | $0.46 |
| 2026-08-07 | #0133 | Fable planning pilot, Decision 5 case-name clause (F) | 182,877 | $2.93 |
| 2026-08-07 | #0132 | Fable planning pass, diff/blame payloads (F) | 183,863 | $2.94 |
| 2026-08-07 | #0132 | Dispatch round 1 (accepted) | 61,228 | $0.49 |
| 2026-08-07 | #0133 | Dispatch round 1 (accepted) | 62,430 | $0.50 |
| 2026-08-07 | #0136 | Fable planning pass, signing payloads (F) | 160,045 | $2.56 |
| 2026-08-07 | #0137 | Dispatch round 1 (accepted) | 63,018 | $0.50 |
| 2026-08-07 | #0134 | Dispatch round 1 (accepted; heredoc thrash, 1.8M local tokens) | 61,778 | $0.49 |
| 2026-08-07 | #0135 | Fable planning pilot + filed #0138 (F) | 211,501 | $3.38 |
| 2026-08-07 | #0135 | Dispatch round 1 (accepted) | 65,678 | $0.53 |
| 2026-08-07 | #0136 | Dispatch round 1 (accepted) | 68,361 | $0.55 |
| 2026-08-07 | #0138 | Dispatch round 1 (accepted) | 60,615 | $0.48 |
| 2026-08-07 | M1 | Fable milestone review; filed #0139-#0145 (F) | 110,872 | $1.77 |
| 2026-08-07 | #0140 | Fable planning pass, non-repository gate (F) | 161,031 | $2.58 |
| 2026-08-07 | #0141 | Fable planning pass, ExitClass + filed #0146 (F) | 144,866 | $2.32 |
| 2026-08-07 | #0140 | Dispatch round 1 (accepted) | 62,011 | $0.50 |
| 2026-08-07 | #0141 | Dispatch round 1 (accepted) | 62,673 | $0.50 |
| 2026-08-07 | #0139 | Fable planning pass, GCResult struct (F) | 148,576 | $2.38 |
| 2026-08-07 | #0139 | Dispatch round 1 (stashed its own work; recovered) | 56,260 | $0.45 |
| 2026-08-07 | #0146 | Fable planning pass + filed #0147 (F) | 154,778 | $2.48 |
| 2026-08-07 | #0146 | Dispatch round 1 (accepted) | 55,482 | $0.44 |
| 2026-08-07 | #0147 | Dispatch round 1 (accepted) | 51,957 | $0.42 |
| 2026-08-07 | #0029 | Fable planning pass + filed #0149/#0150 (F) | 165,982 | $2.66 |
| 2026-08-07 | #0027 | Fable planning pass + filed #0151/#0152 (F) | 243,167 | $3.89 |
| 2026-08-07 | #0029 | Dispatch round 1 FAILED — model reloaded mid-round | 44,296 | $0.35 |
| 2026-08-07 | #0032 | Fable planning pass, flock design (F) | 167,213 | $2.68 |
| 2026-08-07 | #0036 | Fable planning pass, keyless signing verification (F) | 179,259 | $2.87 |
| 2026-08-07 | #0042 | Fable planning pass + filed #0153/#0154 (F) | 189,902 | $3.04 |
| 2026-08-07 | #0029 | Dispatch round 1 re-run (accepted) | 60,369 | $0.48 |
| 2026-08-07 | #0028 | Fable planning pass + filed #0155/#0156/#0157 (F) | 229,612 | $3.67 |
| 2026-08-07 | #0031 | Fable planning pass, union-comparison guard (F) | 221,254 | $3.54 |
| 2026-08-07 | #0041 | Fable planning pass + filed #0158/#0159 (F) | 253,591 | $4.06 |
| 2026-08-07 | #0027 | Dispatch round 1 (accepted) | 73,145 | $0.59 |
| 2026-08-07 | #0043 | Fable planning pass + filed #0160 (F) | 219,170 | $3.51 |
| 2026-08-07 | #0040 | Fable planning pass + filed #0161/#0162 (F) | 234,906 | $3.76 |
| 2026-08-07 | #0037 | Fable planning pass + filed #0163 decision (F) | 169,693 | $2.72 |
| 2026-08-08 | #0033 | Fable planning pass, prune ordering invariant (F) | 241,452 | $3.86 |
| 2026-08-08 | #0030 | Fable planning pass + filed #0164 (F) | 236,059 | $3.78 |
| 2026-08-08 | #0028 | Dispatch r1+r2 + review (O) | 81,851 | $1.31 |
| 2026-08-08 | #0030 | Dispatch r1 + review (O) | 52,592 | $0.84 |
| 2026-08-08 | #0034 | Fable planning: umbrella + filed #0165-#0171 (F) | 280,785 | $4.49 |
| 2026-08-08 | #0030 | Dispatch r2 + review (O) | 101,422 | $1.62 |
| 2026-08-08 | #0165 | Dispatch r1 + review (O) | 58,793 | $0.94 |
| 2026-08-08 | #0165 | Dispatch r2 + review (O) | 52,545 | $0.84 |
| 2026-08-08 | #0166 | Dispatch r1 + review (O) | 61,931 | $0.99 |
| 2026-08-08 | #0032 | Dispatch r1 + review (O) | 66,724 | $1.07 |
| 2026-08-08 | #0155 | Fable planning: re-author to code level (F) | 192,559 | $3.08 |
| 2026-08-08 | #0033 | Dispatch r1 + review (O) | 81,945 | $1.31 |
| 2026-08-08 | #0044 | Fable planning: umbrella + filed #0172, #0173 (F) | 259,409 | $4.15 |
| 2026-08-08 | #0155 | Dispatch r1+r2 + review (O) | 77,907 | $1.25 |
| 2026-08-08 | #0172 | Dispatch r1 + review (O) | 60,037 | $0.96 |
| 2026-08-08 | #0173 | Dispatch r1 + review (O) | 59,906 | $0.96 |
| 2026-08-08 | #0031 | Dispatch r1 + review (O) | 69,312 | $1.11 |
| 2026-08-08 | #0167 | Fable planning: re-author to code level (F) | 219,108 | $3.51 |
| 2026-08-08 | #0042 | Dispatch r1 + review (O) | 71,873 | $1.15 |
| 2026-08-08 | #0168 | Fable planning: re-author + filed #0175 (F) | 301,011 | $4.82 |
| 2026-08-08 | #0167 | Dispatch r1+r2 + review (O) | 75,611 | $1.21 |
| 2026-08-08 | #0041 | Dispatch r1 + review (O) | 72,098 | $1.15 |
| 2026-08-08 | #0170 | Fable planning: re-author to code level (F) | 268,440 | $4.30 |
| 2026-08-08 | #0168 | Dispatch r1+r2 + review (O) | 118,488 | $1.90 |
| 2026-08-08 | #0169 | Fable planning: re-author to code level (F) | 292,247 | $4.68 |
| 2026-08-08 | #0170 | Dispatch r1+r2 + review (O) | 80,548 | $1.29 |
| 2026-08-08 | #0169 | Dispatch r1+r2 + review (O) | 96,364 | $1.54 |
| 2026-08-08 | #0040 | Dispatch r1 + review (O) | 77,021 | $1.23 |
| 2026-08-08 | #0181 | Fable planning: author to code level (F) | 154,773 | $2.48 |
| 2026-08-08 | #0043 | Dispatch r1 + review (O) | 86,092 | $1.38 |
| 2026-08-08 | #0151 | Fable planning: author to code level (F) | 278,794 | $4.46 |
| 2026-08-08 | #0151 | Dispatch r1+r2 + review (O) | 86,127 | $1.38 |
| 2026-08-08 | #0181 | Dispatch r1 + review (O) | 78,108 | $1.25 |
| 2026-08-08 | #0182 | Fable planning: re-author + filed #0185 (F) | 199,317 | $3.19 |
| 2026-08-08 | #0036 | Dispatch r1 + review (O) | 84,049 | $1.34 |
| 2026-08-08 | #0152 | Fable planning: re-author + filed #0186 (F) | 254,722 | $4.08 |
| 2026-08-08 | #0176 #0177 | Fable planning: both authored to code level (F) | 210,849 | $3.37 |
| 2026-08-08 | #0152 | Dispatch r1+r2 + review (O) | 98,394 | $1.57 |
| 2026-08-08 | #0176 #0177 | Dispatch (3 rounds) + review (O) | 117,130 | $1.87 |
| 2026-08-08 | #0182 | Dispatch r1 + review, in-context (O) | 46,000 | $0.74 |
| 2026-08-08 | #0185 | Dispatch r1 + review, in-context (O, estimated) | 38,000 | $0.61 |
| 2026-08-08 | #0184 | Plan + dispatch + review, in-context (O, estimated) | 55,000 | $0.88 |
| 2026-08-08 | #0183 | Plan + dispatch + review, in-context (O, estimated) | 52,000 | $0.83 |
| 2026-08-08 | #0180 | Plan + dispatch + review + hand-fix, in-context (O, estimated) | 68,000 | $1.09 |
| 2026-08-08 | #0179 | Plan + dispatch + review, in-context (O, estimated) | 58,000 | $0.93 |
| 2026-08-08 | #0186 #0187 | Plan + dispatch + review + hand-fix, in-context (O, estimated) | 71,000 | $1.14 |
| 2026-08-08 | #0148 #0174 | Plan + dispatch + review, in-context (O, estimated) | 74,000 | $1.18 |
| 2026-08-08 | #0178 | Plan + dispatch + review, in-context (O, estimated) | 49,000 | $0.78 |
| 2026-08-08 | #0157 | Plan + 3 failed rounds + hand-written tests (O, estimated) | 96,000 | $1.54 |
| 2026-08-09 | #0156 | Written and verified in-context (O, estimated) | 88,000 | $1.41 |
| 2026-08-09 | #0164 | Written and verified in-context (O, estimated) | 74,000 | $1.18 |
| 2026-08-09 | #0174 | Written and verified in-context (O, estimated) | 92,000 | $1.47 |
| 2026-08-09 | #0175 | Filter half written and verified in-context (O, estimated) | 61,000 | $0.98 |
| 2026-08-09 | #0171 | Written and verified in-context (O, estimated) | 105,000 | $1.68 |
| 2026-08-09 | #0035 | Written and verified in-context (O, estimated) | 79,000 | $1.26 |
| 2026-08-17 | #0189 | Implementation round 1, Sonnet subagent (S, measured) | 79,574 | $0.38 |
| 2026-08-17 | #0178 | Implementation rounds 1-2, Sonnet subagent (S, measured) | 197,264 | $0.95 |
| 2026-08-17 | #0161 | Implementation round 1, Sonnet subagent (S, measured) | 82,335 | $0.40 |
| 2026-08-17 | #0153 | Implementation round 1, Sonnet subagent (S, measured) | 115,748 | $0.56 |
| 2026-08-17 | M1 | **Milestone review** (O, measured) | 179,973 | $2.88 |
| 2026-08-17 | #0162 | Implementation round 1, Sonnet subagent (S, measured) | 85,351 | $0.41 |
| 2026-08-17 | #0158 | Implementation round 1, Sonnet subagent (S, measured) | 109,134 | $0.52 |
| 2026-08-17 | #0159 | Implementation round 1, Sonnet subagent (S, measured) | 88,556 | $0.43 |
| 2026-08-17 | #0191 | Implementation round 1, Sonnet subagent (S, measured) | 110,758 | $0.53 |
| 2026-08-17 | #0188 | Implementation round 1, Sonnet subagent (S, measured) | 159,879 | $0.77 |
| 2026-08-17 | #0034 | **Umbrella review** (O, measured) | 127,185 | $2.03 |
| 2026-08-17 | #0190 | Implementation round 1, Sonnet subagent (S, measured) | 88,909 | $0.43 |
| 2026-08-17 | #0192 | Implementation round 1, Sonnet subagent (S, measured) | 75,354 | $0.36 |
| 2026-08-17 | #0149 | Implementation round 1, Sonnet subagent (S, measured) | 142,785 | $0.69 |
| 2026-08-17 | #0044 | **Umbrella review** (O, measured) | 124,667 | $1.99 |
| 2026-08-17 | #0193 | Implementation round 1, Sonnet subagent (S, measured) | 113,207 | $0.54 |
| 2026-08-17 | #0200 | Implementation round 1, Sonnet subagent (S, measured) | 119,281 | $0.57 |
| 2026-08-17 | #0199 | Implementation round 1, Sonnet subagent (S, measured) | 83,488 | $0.40 |
| 2026-08-17 | #0203 | Implementation round 1, Sonnet subagent (S, measured) | 95,511 | $0.46 |
| 2026-08-17 | #0034 | **Umbrella review, second pass** (O, measured) | 97,136 | $1.55 |
| 2026-08-17 | #0202 | Implementation round 1, Sonnet subagent (S, measured) | 130,748 | $0.63 |
| 2026-08-17 | #0201 | Implementation round 1, Sonnet subagent (S, measured) | 102,586 | $0.49 |
| 2026-08-17 | #0196 | Implementation round 1, Sonnet subagent (S, measured) | 97,941 | $0.47 |
| 2026-08-17 | #0204 | Implementation round 1, Sonnet subagent (S, measured) | 115,395 | $0.55 |
| 2026-08-17 | #0195 | Implementation round 1, Sonnet subagent (S, measured) | 100,611 | $0.48 |
| 2026-08-17 | #0205 | Implementation round 1, Sonnet subagent (S, measured) | 126,183 | $0.61 |
| 2026-08-17 | #0034 | **Umbrella review, third pass — closes it** (O, measured) | 103,057 | $1.65 |
| 2026-08-17 | #0198 | Implementation round 1, Sonnet subagent (S, measured) | 89,968 | $0.43 |
| 2026-08-17 | #0197 | Implementation round 1, Sonnet subagent (S, measured) | 166,179 | $0.80 |
| 2026-08-17 | #0207 | Implementation round 1, Sonnet subagent (S, measured) | 132,774 | $0.64 |
| 2026-08-17 | #0206 | Implementation round 1, Sonnet subagent (S, measured) | 136,366 | $0.65 |
| 2026-08-17 | #0038 | Implementation round 1, Sonnet subagent (S, measured) | 101,719 | $0.49 |
| 2026-08-17 | #0175 | Implementation round 1, Sonnet subagent (S, measured) | 144,893 | $0.70 |
| 2026-08-17 | #0208 | Implementation round 1, Sonnet subagent (S, measured) | 132,214 | $0.63 |
| 2026-08-17 | #0044 | **Umbrella review, second pass** (O, measured) | 95,497 | $1.53 |
| 2026-08-17 | #0046 | Implementation rounds 1-2, Sonnet subagent (S, measured) | 214,000 | $1.03 |
| 2026-08-17 | #0047 | Implementation round 1, Sonnet subagent (S, measured) | 103,646 | $0.50 |
| 2026-08-17 | #0039 | Implementation round 1, Sonnet subagent (S, measured) | 167,050 | $0.80 |
| 2026-08-17 | #0039 | Implementation round 2, same agent resumed (S, measured) | 207,419 | $1.00 |
| 2026-08-17 | #0048 | Implementation round 1, Sonnet subagent (S, measured) | 145,108 | $0.70 |
| 2026-08-17 | #0048 | Implementation round 2, same agent resumed (S, measured) | 159,961 | $0.77 |
| 2026-08-17 | #0049 | Implementation round 1, Sonnet subagent (S, measured) | 121,083 | $0.58 |
| 2026-08-17 | #0215 | Implementation round 1, Sonnet subagent (S, measured) | 90,357 | $0.43 |
| 2026-08-17 | #0220 | Implementation round 1, Sonnet subagent (S, measured) | 187,644 | $0.90 |
| 2026-08-17 | #0218 | Implementation round 1, Sonnet subagent (S, measured) | 117,382 | $0.56 |
| 2026-08-17 | #0218 | Implementation round 2, same agent resumed (S, measured) | 135,328 | $0.65 |
| 2026-08-17 | #0211 | Implementation round 1, Sonnet subagent (S, measured) | 140,895 | $0.68 |
| 2026-08-17 | #0223 | Implementation round 1, Sonnet subagent (S, measured) | 94,246 | $0.45 |
| 2026-08-17 | #0211 | Implementation round 2, same agent resumed (S, measured) | 185,430 | $0.89 |
| 2026-08-17 | #0124 | Implementation round 1, Sonnet subagent (S, measured) | 156,050 | $0.75 |
| 2026-08-17 | #0221 | Implementation round 1, Sonnet subagent (S, measured) | 235,109 | $1.13 |
| 2026-08-17 | #0124 | Implementation round 2, same agent resumed (S, measured) | 240,732 | $1.16 |
| 2026-08-17 | #0221 | Implementation round 2, same agent resumed (S, measured) | 265,106 | $1.27 |
| 2026-08-17 | #0124 | Implementation round 3, same agent resumed (S, measured) | 295,324 | $1.42 |
| 2026-08-17 | #0214 | Implementation round 1, Sonnet subagent (S, measured) | 117,012 | $0.56 |
| 2026-08-17 | #0150 | Implementation round 1, Sonnet subagent (S, measured) | 107,929 | $0.52 |
| 2026-08-17 | #0044 | **Umbrella review, third pass** (O, measured) | 136,620 | $2.19 |
| 2026-08-17 | #0230 | Implementation round 1, Sonnet subagent (S, measured) | 106,981 | $0.51 |
| 2026-08-17 | #0160 | **Umbrella review** (O, measured) | 128,578 | $2.06 |
| 2026-08-17 | #0233 | Implementation round 1, Sonnet subagent (S, measured) | 101,048 | $0.49 |
| 2026-08-17 | #0234 | Implementation round 1, Sonnet subagent (S, measured) | 132,198 | $0.63 |
| 2026-08-17 | #0235 | Implementation round 1, Sonnet subagent (S, measured) | 120,978 | $0.58 |
| 2026-08-17 | #0235 | Implementation round 2, same agent resumed (S, measured) | 161,412 | $0.77 |
| 2026-08-17 | #0160 | **Umbrella review, second pass** (O, measured) | 115,475 | $1.85 |
| 2026-08-17 | #0163 | Implementation rounds 1-2, Sonnet subagent (S, measured) | 472,127 | $2.27 |
| 2026-08-17 | #0236 | Implementation round 1, Sonnet subagent (S, measured) | 138,961 | $0.67 |
| 2026-08-17 | #0239 | Implementation round 1, Sonnet subagent (S, measured) | 107,062 | $0.51 |
| 2026-08-17 | #0238 | Implementation round 1, Sonnet subagent (S, measured) | 95,847 | $0.46 |
| 2026-08-17 | #0237 | Implementation round 1, Sonnet subagent (S, measured) | 215,745 | $1.04 |
| 2026-08-17 | #0240 | Investigation round 1, Sonnet subagent (S, measured) | 69,156 | $0.33 |
| 2026-08-17 | #0240 | Investigation rounds 2-3, same agent resumed (S, measured) | 341,034 | $1.64 |
| 2026-08-17 | #0160 | **Umbrella review, third pass** (O, measured) | 104,896 | $1.68 |
| 2026-08-17 | #0242 | Implementation round 1, Sonnet subagent (S, measured) | 145,181 | $0.70 |
| 2026-08-17 | #0241 | Implementation round 1, Sonnet subagent (S, measured) | 186,026 | $0.89 |
| 2026-08-17 | #0231 | Implementation round 1, Sonnet subagent (S, measured) | 238,947 | $1.15 |
| 2026-08-17 | #0194 | Implementation round 1, Sonnet subagent (S, measured) | 143,328 | $0.69 |
| 2026-08-17 | #0232 | Implementation rounds 1-2, Sonnet subagent (S, measured) | 687,049 | $3.30 |
| 2026-08-17 | #0244 | Implementation round 1, Sonnet subagent (S, measured) | 131,829 | $0.63 |
| 2026-08-17 | M1 | **Milestone review** (O, measured) | 147,793 | $2.36 |
| 2026-08-17 | #0245 | Implementation round 1, Sonnet subagent (S, measured) | 94,548 | $0.45 |
| 2026-08-17 | #0246 | Implementation round 1, Sonnet subagent (S, measured) | 130,776 | $0.63 |
| 2026-08-17 | M1 | **Milestone review, second pass** (O, measured) | 100,549 | $1.61 |
| 2026-08-17 | #0247 | Implementation round 1, Sonnet subagent (S, measured) | 98,185 | $0.47 |
| 2026-08-17 | #0044 | **Umbrella review, fourth pass** (O, measured) | 127,098 | $2.03 |
| 2026-08-17 | #0249 | Implementation round 1, Sonnet subagent (S, measured) | 66,727 | $0.32 |
| 2026-08-17 | #0250 | Implementation round 1, Sonnet subagent (S, measured) | 107,527 | $0.52 |
| 2026-08-17 | #0248 | Implementation round 1, Sonnet subagent (S, measured) | 223,397 | $1.07 |
| 2026-08-17 | #0252 | Implementation round 1, Sonnet subagent (S, measured) | 125,398 | $0.60 |
| 2026-08-17 | #0160 | **Umbrella review, fourth pass** (O, measured) | 141,643 | $2.27 |
| 2026-08-17 | #0044 | **Umbrella review, fifth pass** (O, measured) | 157,227 | $2.52 |
| 2026-08-17 | #0255 | Implementation round 1, Sonnet subagent (S, measured) | 149,270 | $0.72 |
| 2026-08-17 | #0251 | Implementation round 1, Sonnet subagent (S, measured) | 220,537 | $1.06 |
| 2026-08-17 | #0253 | Implementation round 1, Sonnet subagent (S, measured) | 268,735 | $1.29 |
| 2026-08-17 | M1 | **Milestone review, third pass** (O, measured) | 163,524 | $2.62 |
| 2026-08-17 | #0254 | Implementation round 1, Sonnet subagent (S, measured) | 136,599 | $0.66 |
| 2026-08-18 | #0254 | Hazard probe, same subagent resumed (S, measured) | 150,449 | $0.72 |
| 2026-08-18 | #0256 | Implementation round 1, Sonnet subagent (S, measured) | 166,943 | $0.80 |
| 2026-08-18 | #0257 | Implementation round 1, Sonnet subagent (S, measured) | 110,075 | $0.53 |
| 2026-08-18 | #0261 | Implementation round 1, Sonnet subagent (S, measured) | 118,275 | $0.57 |
| 2026-08-18 | #0256 | Implementation round 2, Sonnet subagent (S, measured) | 143,606 | $0.69 |
| 2026-08-18 | #0259 | Implementation round 1, Sonnet subagent (S, measured) | 119,537 | $0.57 |
| 2026-08-18 | #0260 | Implementation round 1, Sonnet subagent (S, measured) | 147,827 | $0.71 |
| 2026-08-18 | #0262 | Implementation rounds 1-2, Sonnet subagent (S, measured) | 246,771 | $1.18 |
| 2026-08-18 | #0044 | **Umbrella review, sixth pass** (O, measured) | 154,695 | $2.48 |
| 2026-08-18 | #0160 | **Umbrella review, fifth pass** (O, measured) | 135,003 | $2.16 |
| 2026-08-18 | #0263 | Implementation round 1, Sonnet subagent (S, measured) | 105,445 | $0.51 |
| 2026-08-18 | #0264 | Implementation round 1, Sonnet subagent (S, measured) | 247,581 | $1.19 |
| 2026-08-18 | M1 | **Milestone review, fourth pass** (O, measured) | 151,936 | $2.43 |
| 2026-08-18 | #0265 | Implementation round 1, Sonnet subagent (S, measured) | 81,084 | $0.39 |
| 2026-08-18 | #0267 | Implementation round 1, Sonnet subagent (S, measured) | 87,968 | $0.42 |
| 2026-08-18 | #0266 | Implementation round 1, Sonnet subagent (S, measured) | 79,455 | $0.38 |
| | | **Total measured** | **31,642,003** | **$332.53** |

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

## Ornith — the local model

Tracked separately in **[ornith-tally.md](ornith-tally.md)**, regenerated by
`./scripts/ornith-tally.sh --write`. This file covers the hosted side — authoring and review in Opus
tokens, which is the number that is not zero.

**Do not mirror those figures here.** Twenty-three per-issue Ornith rows were added to the table
above during 2026-08-08 and removed the same day: reconciling them against the tally found two
issues **double-counted** (#0030 and #0165 — a cumulative row added without removing the earlier
per-round one), one short by 513,723 tokens, and seventy-five missing outright. The mirror drifted
within a single day.

The two halves have genuinely different sources, and that is the whole reason they are kept
differently. Dispatcher and planner figures are reported **once**, in a completion notification, and
exist nowhere else — so they are hand-written the moment they are measured, and anything missed is
unrecoverable. Ornith figures live in OpenCode's SQLite database, which **survives the session**, so
hand-maintaining them buys nothing and costs accuracy.
