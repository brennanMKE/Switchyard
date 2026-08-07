# Coding Benchmarks: Claude Sonnet 5 vs Ornith 1.0

**Compiled:** 2026-08-07
**Scope:** Published coding and agentic-coding benchmark results for Anthropic's Claude Sonnet 5 and DeepReinforce AI's Ornith 1.0 family.

---

## Read this first

The two models do not have symmetric evidence behind them, and any table that presents their scores side by side without saying so is misleading.

- **Claude Sonnet 5** has both vendor-reported scores and at least one genuinely independent evaluation (Vals AI, run on the standard Terminus 2 harness).
- **Ornith 1.0** has vendor-reported scores only. As of this compile date, no independent evaluator has published a run. Ornith does not appear on the Vals AI Terminal-Bench 2.1 leaderboard, and BenchLM tracks the model but excludes it from its public leaderboard for insufficient non-vendor coverage (7 of 381 tracked benchmark slots have displayable evidence).

A second problem: SWE-bench and Terminal-Bench are third-party *benchmarks*, but almost every published score is a *self-reported run*. The benchmark is neutral; the harness, effort setting, retry policy, and template are not. Treat vendor numbers as claims, not measurements.

---

## Independently run results

Only one row here has data for both models. That is the finding.

| Benchmark | Harness | Evaluator | Claude Sonnet 5 | Ornith-1.0-397B |
|---|---|---|---|---|
| Terminal-Bench 2.1 | Terminus 2, pass@1 | Vals AI | 74.53% | not evaluated |

Context from the same Vals AI board (2026-08-06): GPT-5.6 Sol 85.77%, Claude Opus 5 84.64%, Kimi K3 80.90%, Claude Fable 5 80.52%, GPT-5.6 Luna 79.03%, GPT-5.5 76.40%.

Note the gap between Anthropic's own Terminal-Bench 2.1 figure (80.4) and Vals AI's independent run of the same benchmark (74.53). That roughly 6-point spread on a single model, single benchmark, is the best available estimate of how much harness and configuration choices are worth. Apply it as an error bar to every vendor number below.

---

## Vendor-reported results

### Ornith 1.0 (DeepReinforce AI, self-reported)

| Benchmark | 397B MoE | 35B MoE | 9B Dense |
|---|---|---|---|
| Terminal-Bench 2.1 (Terminus-2) | 77.5 | 64.2 | 43.1 |
| Terminal-Bench 2.1 (Claude Code) | 78.2 | 62.8 | 40.6 |
| SWE-bench Verified | 82.4 | 75.6 | 69.4 |
| SWE-bench Pro | 62.2 | 50.4 | 42.9 |
| SWE-bench Multilingual | 78.9 | 69.3 | 52.0 |
| NL2Repo | 48.2 | 34.6 | 27.2 |
| ClawEval (avg) | 77.1 | 69.8 | 63.1 |

### Claude Sonnet 5 (Anthropic, self-reported)

| Benchmark | Score |
|---|---|
| SWE-bench Pro | 63.2 |
| Terminal-Bench 2.1 | 80.4 |
| OSWorld-Verified | 81.2 |
| SWE-bench Verified | not cleanly published |

**Caution on the Sonnet 5 numbers.** Anthropic published its launch benchmark table as an image, and the capabilities section of the system card sits deep in a 145-page PDF. The figures above come from secondary coverage citing the launch blog, where multiple independent write-ups agree. Anthropic led with SWE-bench **Pro**, not Verified. Widely circulated Verified figures for Sonnet 5 (72.7, 82.1, 85.2, 92.4) do not agree with each other and at least one analysis states these do not appear in Anthropic's announcement, pricing docs, or system card. Some sources also give an incorrect February 2026 release date; the correct date is 2026-06-30. **Do not cite a SWE-bench Verified number for Sonnet 5 without a primary source.**

---

## Where both have numbers

| Benchmark | Ornith-1.0-397B | Claude Sonnet 5 | Comparable? |
|---|---|---|---|
| SWE-bench Pro | 62.2 | 63.2 | No, different harnesses |
| Terminal-Bench 2.1 | 77.5 | 80.4 vendor / 74.53 independent | Partially |

Rough read: at flagship scale, Ornith-397B lands in the same band as Sonnet 5 on the harder coding benchmarks. Neither gap exceeds the harness-variance estimate above, so treat them as a tie pending independent verification of Ornith.

---

## Harness and methodology differences

These are why the tables above cannot be read as a like-for-like comparison.

| | Ornith 1.0 | Claude Sonnet 5 |
|---|---|---|
| SWE-bench harness | OpenHands, temp 1.0, top_p 0.95, 256K ctx | Anthropic internal |
| Terminal-Bench harness | Harbor/Terminus-2 and Claude Code 2.1.126, temp 1.0, 128K ctx, 5-run average | Anthropic internal |
| Modifications | Qwen chat template adjusted; Harbor patched for vLLM `reasoning_content` | Effort parameter (low to xhigh); published figures reflect strong-effort runs |

Two structural issues worth calling out:

1. **Ornith's core method is scaffold optimization.** Its stated contribution is an RL loop that learns task-specific harnesses jointly with solutions. Benchmarks measure model plus harness. The quantity being optimized and the quantity being scored are the same thing. DeepReinforce discloses this risk and describes three defenses (immutable trust boundary, deterministic monitor, frozen LLM judge as veto). Disclosure is not resolution.
2. **Sonnet 5's scores move with the effort parameter.** Headline figures reflect high effort. At medium effort, cost efficiency improves and scores drop; at xhigh, cost can exceed Opus 4.8. A single Sonnet 5 number without an effort level attached is underspecified.

---

## Errors in the Ornith launch page

Flagged because they affect confidence in the source, not because they are individually large.

- Intro says the 397B "matches the performance of Claude Opus 4.7," then two paragraphs later says it surpasses Opus 4.7 on both benchmarks.
- Intro cites MiniMax M3 at 66.0 and DeepSeek-V4-Pro at 67.9 on Terminal-Bench 2.1; the full table lists both at 64.
- Intro cites the 35B at 64.4 on Terminal-Bench 2.1; the table says 64.2.
- The launch page says the family is built on "Gemma 4 and Qwen 3.5" without mapping bases to sizes. Secondary sources indicate the 397B is specifically Qwen 3.5 MoE. Unconfirmed by the vendor.

---

## Non-benchmark differences that may matter more

| | Ornith 1.0 | Claude Sonnet 5 |
|---|---|---|
| Weights | Open, MIT licensed, on Hugging Face | Closed, API only |
| Sizes | 9B dense, 31B dense, 35B MoE, 397B MoE | n/a |
| Context | 256K | 1M |
| Serving | 397B needs ~8x80GB GPU node (TP 8); 9B/35B are single-GPU or Apple Silicon viable | Hosted |
| Pricing | Infrastructure cost only | $2/$10 per MTok intro through 2026-08-31, then $3/$15 |
| Reasoning | `<think>` blocks by default, needs a reasoning parser | Extended thinking, effort parameter |

If the decision is "can I run this myself," the 397B-vs-Sonnet-5 comparison is beside the point. The 9B and 35B checkpoints are the ones that change what is possible locally, and their scores (43.1 and 64.2 on Terminal-Bench 2.1) are far below either flagship.

---

## What this document does not establish

- That Ornith's reported scores replicate under a neutral harness. Nobody has published a run.
- Any SWE-bench Verified comparison. Sonnet 5 lacks a reliable published figure.
- Real-world coding performance. Both benchmarks are agentic-task proxies, and SWE-bench Verified in particular is approaching saturation at the frontier.
- Cost per solved task, latency, or refusal behavior under agentic load.

The only reliable way to compare these two for a specific project is to run both against your own task set on one harness you control.

---

## Sources

| Source | Type | URL |
|---|---|---|
| Ornith 1.0 launch page | Vendor | https://ornith.ai/ornith_1_0.html |
| Ornith-1.0-397B model card | Vendor | https://huggingface.co/deepreinforce-ai/Ornith-1.0-397B |
| Ornith-1.0-9B model card | Vendor | https://huggingface.co/deepreinforce-ai/Ornith-1.0-9B |
| Introducing Claude Sonnet 5 | Vendor | https://www.anthropic.com/news/claude-sonnet-5 |
| Claude Sonnet 5 System Card | Vendor | https://www.anthropic.com/claude-sonnet-5-system-card |
| Vals AI Terminal-Bench 2.1 | Independent | https://www.vals.ai/benchmarks/terminal-bench-2-1 |
| BenchLM Ornith-1.0-397B profile | Aggregator | https://benchlm.ai/models/ornith-1-0-397b |
| Terminal-Bench project | Benchmark | https://www.tbench.ai/ |

**Revalidation:** Independent evaluation of Ornith 1.0 was pending as of mid-2026. Re-check the Vals AI and tbench.ai leaderboards before relying on this document.
