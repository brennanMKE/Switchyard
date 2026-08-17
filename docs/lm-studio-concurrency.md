# LM Studio concurrency for Ornith dispatches

**HISTORICAL — the local model was retired on 2026-08-16** and implementation moved to Sonnet
subagents. Nothing in this file constrains the current workflow; it is kept as the measurement
record behind the concurrency decisions made while it did. See `docs/workflow-reset-2026-08-16.md`.

**Measured 2026-08-07 on the model host** (`brennan-mac-mini-m4.local`, M4 Pro, 64 GB), against
`ornith-1.0-35b-mlx-oq8` loaded at `--context-length 65536`. Supersedes the `PARALLEL 2` ceiling
asserted in `CLAUDE.md` § "Concurrency ceiling" and in `docs/review-failures.md` preflight rule 7.

**Verdict: 4 concurrent dispatches work.** Memory is not the constraint and context is not divided.
The cost is per-round latency, which is what interacts with the two watchdogs in
`scripts/dispatch-issue.sh` — that, not throughput, is what has to be adjusted before adopting 4.

## The limit was never a model or licensing constraint

It is a load-time flag. `opencode-ornith.sh:41` in `~/Developer/LM Studio` runs:

    lms load ornith-1.0-35b-mlx-oq8 --context-length 65536 --parallel 2 -y

`lms load --help` defines `--parallel` as "maximum number of predictions the model can run at a
given time." It allocates prediction slots at load time, which is why changing it requires a
reload. Requests beyond the slot count **queue silently** — no `429`, no error, just latency. That
silence is what preflight rule 7 exists to catch.

Slots are allocated at load, so the model must be reloaded to change the count:

    lms unload --all
    lms load ornith-1.0-35b-mlx-oq8 --context-length 65536 --parallel 4 -y

**`unload --all` first is mandatory, not hygiene.** `lms load` adds an instance rather than
replacing one; issuing it against a live 37.73 GB model tries to hold two at once and dies with
"Model loading was stopped due to insufficient system resources," which reads as though the *new*
setting was rejected. It was not. The existing instance survives that failure untouched.

**`--estimate-only` is useless here.** It reports an identical 49.19 GiB for `--parallel 2` and
`--parallel 4`, is marked `Confidence: LOW`, and predicts "will fail to load" for a configuration
that was loaded and serving at the time. It does not model the flag. Ignore it and measure.

## Context is per slot, not a divided pool

The open question was whether `--context-length 65536` is a pool split across slots — the
llama.cpp behaviour, where `n_ctx` divides by `n_parallel`. If it were, `--parallel 4` would
silently cut every round to 16,384 tokens and rounds would fail in a way easily misread as model
flakiness.

It does not. At `PARALLEL 4`, a single request of **42,601 prompt tokens** was accepted and
answered. Four *simultaneous* requests of 49,311 tokens each also all succeeded. Each slot gets the
full 65,536.

## Memory is not the constraint

Ornith is a hybrid architecture, which makes extra slots far cheaper than a dense transformer would
suggest. From `config.json`: 40 layers, but `layer_types` marks only every 4th as `full_attention`
(10 total); the other 30 are `linear_attention` carrying a fixed-size recurrent state.

- **Attention KV** — 10 full-attention layers x 2 KV heads x 256 `head_dim` x 2 (K+V) x 2 bytes
  = 20 KiB/token, so **~1.25 GiB per slot** at 64k.
- **Linear-attention state** — 30 layers x 32 value heads x 128 x 128 x 4 bytes (`mamba_ssm_dtype`
  is float32) ≈ **60 MiB per slot**, constant regardless of context length.

About **1.3 GiB per slot**, against ~22 GB of headroom. Confirmed empirically: four concurrent
25,311-token requests moved swap not at all — `used = 5081.12M` before and `used = 5081.12M`
after. Going to 4 costs roughly 2.6 GiB over 2.

## Throughput: 4 is a real gain

Decode, identical 299-token completions, warmed:

| Concurrency | Per-stream | Aggregate |
|---|---|---|
| 1 | 52.4 tok/s | 52.4 |
| 2 | 35.8 | 71.3 |
| 3 | 27.9 | 83.1 |
| **4** | **21.7** | **86.5** |
| 6 | 13.6–22.3 | 81.9 |
| 8 | 10.9–22.5 | 86.8 |

Aggregate saturates at 4. Past it there is no gain at all, and the widening per-stream spread is
the queueing signature — slots beyond the cap waiting. **8 concurrent dispatches would buy nothing
over 4.**

Prefill, 49,311 tokens per request, distinct prefixes:

| | Wall | Aggregate prefill |
|---|---|---|
| 1 request | 107.7s (458 tok/s, n=3, ±1%) | 458 tok/s |
| 4 concurrent | 239.2s | **825 tok/s** |

The four returned in a staircase — 68.8 / 128.5 / 187.7 / 239.2s — so prefill parallelizes only
partially. Still a **+80% aggregate** gain: 4 sequential 49k prefills would take ~431s against 239s
run together.

### A measurement trap worth recording

An earlier pass concluded the opposite — that concurrent prefill was ~50% *slower* than sequential.
That was an artifact. The sequential baselines were probes of 14.6k / 28.6k / 42.6k tokens built
from a **shared prefix**, so probes 2 and 3 were served largely from prefix cache and reported
22.7s / 28.1s / 34.4s — a nearly flat curve implying ~1,238 tok/s. The true uncached rate is
458 tok/s, stable to ±1% across three runs. **Any prefill benchmark against this server must use a
distinct prefix per request**, or it measures the cache and inverts the conclusion.

This matters beyond benchmarking: it is direct evidence the server *does* reuse cached prefixes,
which makes the `cacheR=0` observation in `docs/review-failures.md` (#0124 — 49k re-sent twelve
times, 438,301 input tokens for a context that never exceeded 49k) a client-side problem in how
OpenCode structures its requests, not a server limitation.

## What this costs a single round — the part that matters

Aggregate throughput improves; **individual rounds get slower**, roughly linearly with queue
position. At 4-way concurrency a round sees ~2.2–2.4x its solo latency (decode 52.4 → 21.7 tok/s;
last-in 49k prefill 107.7s → 239.2s). Four rounds at 2.3x each is still a net ~1.7x more work per
hour — but both watchdogs in `scripts/dispatch-issue.sh` are **fixed wall-clock values**, and
neither scales with load:

- **`STALL=420`** (`dispatch-issue.sh:30`) kills a round after 420s with no growth in the log's
  mtime. Prefill emits nothing. The last of four concurrent 49k rounds sits silent for **239s** per
  turn — inside the limit, but only 1.8x margin, and that margin shrinks as contexts approach the
  65,536 ceiling.
- **`TIMEOUT=1800`** (`dispatch-issue.sh:27`) bounds the whole round. This is the tighter
  constraint: a round that converges in 800s solo lands near 1,840s at 4-way and gets killed as
  non-converging. Rounds that currently finish comfortably would start timing out, and
  `docs/review-failures.md` would fill with `environment` rows describing nothing worse than
  contention.

Compounding both: with `cacheR=0`, every turn re-prefills the full context, so the 239s is paid per
turn rather than once per round.

## Raw throughput is not the metric — do not go to 4

Everything above says 4 slots are affordable and raise aggregate tokens/sec. That is the wrong
metric for this project, and acting on it would make progress *slower*.

Per-round slowdown `S(N)` from measured per-stream decode, and the resulting round throughput
`N / S(N)`:

| Concurrency | `S(N)` | Rounds/hour (relative) |
|---|---|---|
| 1 | 1.00x | 1.00 |
| 2 | 1.46x | 1.37 |
| 3 | 1.88x | 1.60 |
| 4 | 2.41x | 1.66 |

Raw throughput favours 4. But a round killed at `TIMEOUT` is not work — it burns a full slot,
yields nothing, and needs a retry. `docs/review-failures.md` contains **eight rounds at 1800s**,
already dying at the ceiling at `PARALLEL 2`. Rescaling observed durations:

| Observed at `PARALLEL 2` | At `PARALLEL 1` | At `PARALLEL 4` |
|---|---|---|
| 1800s (timeout kill, x8) | **1233s — completes** | dead |
| 1289s | 883s | 2127s — **dies** |
| 1113s | 762s | 1836s — **dies** |
| 1044s | 715s | 1723s |

**4 converts currently-succeeding rounds into timeout kills. 1 rescues every round now dying at the
ceiling.** Serial beats `PARALLEL 2` whenever more than ~27% of round-time at 2 is lost to
timeouts — the gap between 1.00 and 1.37.

That fraction is measurable and currently is not being measured. `dispatch-issue.sh:206` writes a
`timedOut` field on every completion record, but `.switchyard-runs/` retains only two logs. **Retain
the completion records, then compute the timeout fraction and let it decide 1 vs 2.**

A second argument for serial that has nothing to do with tokens: this project's throughput comes
from the failure-learning loop in `docs/review-failures.md` — rule 8, rule 9 and the stall watchdog
each came from a specific failed round. Serial rounds let round N+1 carry round N's lesson. Four
parallel rounds reproduce the same defect four times before any lesson lands.

## `cacheR=0` is a reporting gap, not a cache miss — do not "fix" it

An earlier revision of this document claimed `cacheR=0` meant prefixes were being re-ingested every
turn, costing ~850s per round, and called it the highest-leverage fix available. **That was wrong.**
LM Studio's own server log settles it. Every request emits a line like:

    [coordinator][INFO]: Prompt cache restore: cached_tokens=37464 uncached_tokens=19
                          lifetime_efficiency=90.58%

Over the 12 hours to 2026-08-08 19:46, across **502 cache-restore events** covering 34 dispatch
rounds:

| | |
|---|---|
| Cached tokens served | 14,048,586 |
| Uncached tokens processed | 1,163,423 |
| **Hit rate** | **92.35%** |
| `lifetime_efficiency` range | 87.64% – 94.35% |
| Median uncached tokens per request | **183** |

The server reuses prefixes aggressively. OpenCode's `tokens_cache_read` column is `0` on all 34
sessions because the OpenAI-compatible endpoint returns no `cached_tokens` field for the client to
record — **the counter is unpopulated, not zero**. The `438,301 input tokens` figure in #0124 is a
count of tokens *submitted*, not tokens *processed*.

A whole-window time budget confirms it, and is the reason to trust the log over the client:

| | |
|---|---|
| Uncached prefill (1,163,423 tok @ 458 tok/s) | 2,540s |
| Decode (188,535 tok @ 54 tok/s) | 3,491s |
| **Modeled busy time** | **6,032s** |
| **Measured busy time** (log stream timings) | **6,884s** |

Within 12%, with the remainder in tokenization and sampling overhead. Had the cache genuinely been
cold, the same traffic would have required **30,674s (8.5 hours) of additional prefill** — which
does not fit in a 12-hour window that was only 16% busy. **There is nothing to fix here.**

## The slot count costs nothing when it is not used

`--parallel` sets a *ceiling*, not a reservation. Slots are allocated on demand, so configuring 4
and dispatching one round at a time is free. Measured A/B, same single-stream workload, model
reloaded between configurations:

| Single stream | `PARALLEL 4` | `PARALLEL 1` |
|---|---|---|
| Decode | 54.4 / 53.7 tok/s | 53.4 / 51.5 tok/s |
| Prefill (57,711 tok) | 425.7 / 450.8 tok/s | 445.8 / 369.1 tok/s |
| Wired memory after use | 42.25 GB | 42.12 GB |

No penalty on either axis, and the 0.13 GB memory delta is noise — **there is no per-slot
preallocation**. (Run-to-run prefill variance is wide, 369–451 tok/s, so treat any prefill
difference under ~15% as unmeasurable.)

The two settings differ only in how they fail when dispatch discipline slips:

- At `PARALLEL 2`, a third dispatch **queues**. `dispatch-issue.sh` starts its wall clock when
  `opencode run` launches, not when the server picks the request up, so a queued round burns its
  `TIMEOUT` budget sitting idle and can die having done nothing. This is visible in the concurrency
  table above: the wide per-stream spread at 6 and 8 is queue wait counted as elapsed.
- At `PARALLEL 4`, that dispatch **runs** instead, degrading rounds rather than stalling one — but
  it also permits four-way contention, where the per-round penalty reaches 2.41x and rounds that
  succeed today start hitting the 1800s ceiling.

## Settings — stay at `PARALLEL 2`

**Decision (2026-08-07): keep `--parallel 2`.** The measurements above show 4 would cost nothing
*if* only one round is ever dispatched at a time, but that is a discipline guarantee rather than an
enforced one. 2 is the safer ceiling: it bounds worst-case degradation at 1.46x instead of 2.41x,
which keeps accidental concurrency well clear of the `TIMEOUT=1800` cliff that has already killed
eight rounds. The upside of 4 is available only under perfect discipline; the downside arrives on
its own.

    lms unload --all
    lms load ornith-1.0-35b-mlx-oq8 --context-length 65536 --parallel 2 -y

`opencode-ornith.sh` already passes `--parallel 2`, so no change is needed there and a prep run
restores the intended state. `CLAUDE.md` § "Concurrency ceiling" and preflight rule 7 remain
correct as written. `TIMEOUT=1800` and `STALL=420` (`dispatch-issue.sh:27,30`) stay as they are.

**If 4 is ever revisited**, it is viable only alongside enforced serialization of dispatches, and
`TIMEOUT`/`STALL` must rise to ~4200/~900 in the same change or contention failures will be
misfiled as `environment`. **Never exceed 4** — aggregate throughput is flat from 4 to 8 while
per-round latency keeps degrading.

## Verifying the setting is live

`lms ps` reports it directly — the `PARALLEL` column is authoritative, and worth checking in
preflight rather than assuming:

    IDENTIFIER                MODEL                     STATUS   SIZE       CONTEXT   PARALLEL
    ornith-1.0-35b-mlx-oq8    ornith-1.0-35b-mlx-oq8    IDLE     37.73 GB   65536     4

**Current state: the host is loaded at `PARALLEL 4`.** `opencode-ornith.sh` still passes
`--parallel 2`, so re-running that script reverts to 2 — reconcile the script with whichever
setting is adopted, or the next prep run will silently undo it.

---

## Adopted policy, 2026-08-07

**Host stays at `--parallel 4`; Switchyard dispatches one round at a time.**

The recommendation above is about capacity and it stands. The policy on top of it is different,
because the number that matters to this queue is **per-round latency, not aggregate throughput**:

- Decode is **52.4 tok/s solo against 21.7 at 4-way**. A serialised round lands ~2.4x sooner.
- Measured slot occupancy over a real four-hour window of dispatches was **0.44 of 2 slots** — the
  ceiling was never binding. 1.8 hours of model time spread across 4 hours of wall clock.
- The real constraint is **planning**: every issue needs a planning pass of 10–20 minutes before a
  dispatch of 5–9 minutes. Dispatch is the short leg. Planning has no host ceiling, so throughput comes from
  running planners ahead of the queue.
- Review is serial regardless — one reviewer, running mutations and merging — so four rounds
  finishing together would queue behind it anyway.

The host is left at 4 so the capacity is available without a reload, and because a reload kills any
in-flight round (#0029 round 1 died exactly that way).

**Consequences already applied:** `DISPATCH_CEILING=1` in `preflight-issue.sh`; watchdogs back to
`TIMEOUT=1800` / `STALL=420` / `QUIET_LIMIT=450`, since the 2.3x contention penalty they compensated
for no longer applies and a slack timeout means a hung round burns 70 minutes instead of 30.

**If the ceiling ever goes back above 1, raise all three watchdogs with it.**
