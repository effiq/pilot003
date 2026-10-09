# Pilot 003 — Verdict

**Tuned FP8 quantization (attention-exempt) vs BF16, red-dot repair attempt, pre-registered dual gates.**

| gate | result | headline number |
|---|---|---|
| Quality (stage 08) | **PASS** | worst-judge overall delta **+0.102** vs tolerance −0.1; original red-dot judge reversed clarity −0.127 → **+0.033** |
| Performance (stage 09) | **FAIL** | point estimate **1.6344×**, paired-bootstrap 95% CI **[1.4328, 2.0062]×** vs pre-registered bar: CI lower ≥ 1.50× |

**PILOT 003 VERDICT: FAIL.** The combined claim — "the tuned configuration repairs the
published clarity red dot AND clears the 1.50× performance bar" — does NOT hold,
because the second conjunct does not hold. The repair itself is real and sealed:
on the frozen 150-item set, under a three-judge panel that includes the judge that
issued the red dot, every axis of every judge is within tolerance. The performance
gain is also real (continuity reference 1.20×: PASS; CI lower 1.4328×), but the
pre-registered commercial bar was 1.50×, the confidence interval straddles it, and
no straddle extension was pre-registered — n = 6 decides. Both gates are published
as measured, with raw logs, in the public `effiq/pilot-logs` archive. A FAIL here
publishes in full per PREREG-ADDENDUM-02 §5.

---

## 1. Setup

| | |
|---|---|
| Model | Qwen/Qwen2.5-14B-Instruct @ `cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8` |
| Serving stack | vLLM 0.31.0 (pinned), single NVIDIA L40S, max_model_len 32768, prefix caching off |
| Arm A | BF16 defaults |
| Arm C | tuned FP8: FP8 dynamic with attention projections exempted (arm a4-exempt-attn; recipe sha256 `5065e67e…df8`; recipe body is gate-layer material, hash-pinned per ADDENDUM-02 §4) |
| Checkpoint | built with llmcompressor 0.12.0; full-tree sha256 `539cee71…c420`; built → served → measured → deleted, hash-anchored; rebuilt byte-identically three times (screening / confirm / performance) |
| Traffic | Azure LLM Inference Trace 2024, same six hour-aligned window pairs as Pilot 002 (TRACE_SEED 20261010), same operating point r = 1/256, C = 4 (calibration fallback; disclosure carried into every summary) |
| Design | block-interleaved arms, request-level pairing by request_id within run; identical statistics to Pilot 002 stage 04 (paired bootstrap, seed 20262002, 100,000 resamples) |
| Protocol | PREREG-ADDENDUM-02, frozen 2026-10-08 before any execution (repo commit `7866ed2`), with execution-time disclosures in ADDENDUM-03/04/05/06 (see §7) |

Pilot 003 is an optimization pilot, not a benchmark: two phases (screening, then a
single confirmation shot) with the confirmation gates frozen before any GPU run.

## 2. Phase 1 — lever screening (stage 07, indicative)

40 screening items, disjoint from the frozen 150 (zero-overlap asserted at build);
single cheap judge (`deepseek-chat-v3.1`); blind seed 20261014; 320/320 rows judged.
Screening is directional only — it selects, it does not decide.

| arm | levers | clarity delta | overall delta |
|---|---|---|---|
| a1-control (exact Pilot 002 arm-B config) | 0 | **−0.250** | −0.067 |
| a2-smooth | 1 | −0.075 | +0.050 |
| a3-calib-static | 1 | −0.225 | −0.217 |
| **a4-exempt-attn** | 1 | **+0.350** | **+0.450** |
| a5-exempt-down | 1 | +0.075 | +0.142 |
| a6-all | 3 | +0.125 | +0.217 |
| a7-w2 (merge of top-2) | 2 | +0.275 | +0.458 |
| a8-w2 (merge of top-1,3) | 2 | +0.175 | +0.108 |

Two observations worth publishing on their own:

- **The pipeline detects the red dot it was built to repair.** a1-control — the exact
  configuration that breached tolerance in Pilot 002 — reproduces the breach on the
  screening set (−0.250 vs tolerance −0.1). The screening instrument is sensitive to
  the defect class under repair.
- **The winner is a single-lever arm.** Selection rule (frozen): clarity first,
  simplicity breaks ties. a4-exempt-attn (+0.350 clarity, 1 lever) beat both wave-2
  combinations on the primary axis. Winner's descriptive CI [−0.250, +0.975] crosses
  zero at n = 40 — exactly why the confirm phase exists. Outcome: PROCEED.

## 3. Quality gate (stage 08, single-shot confirmation)

Frozen-150 set (sha256 `728b2f83…5cf7d`), blind map reused from the sealed Pilot 002
archive (identical presentation order), serving-mode generation at temperature 0.
Panel (frozen rules): seat 1 mandatory — `deepseek-chat-v3-0324`, the original
red-dot judge; seats 2–3 probed in order; ≥ 2 vendor families required. Panel formed:
**0324, z-ai/glm-4.6, deepseek-v3.1-terminus**; 450/450 judgments completed.

| judge | correctness | instruction_following | clarity | overall | gate |
|---|---|---|---|---|---|
| deepseek-chat-v3-0324 (original red-dot judge) | +0.087 | +0.187 | **+0.033** | +0.102 | PASS |
| z-ai/glm-4.6 | +0.213 | +0.167 | +0.087 | +0.156 | PASS |
| deepseek-v3.1-terminus | +0.373 | +0.460 | +0.360 | +0.398 | PASS |

Worst-judge rule (all three must pass): **QUALITY GATE: PASS** (worst = 0324, +0.102).
The judge that issued the −0.127 red dot scores the tuned arm **+0.033** on the same
150 answers' successor set — the red dot is repaired on its own issuer's scale.
Descriptive clarity-delta CIs: 0324 [−0.253, +0.320]; glm-4.6 [−0.133, +0.320];
terminus [+0.020, +0.700] — per protocol the gate uses point estimates; the
terminus CI excludes zero, the other two do not.

## 4. Performance gate (stage 09, sealed verdict)

Six formal runs, block-interleaved, 6,552 paired requests per arm
(459 / 794 / 1754 / 1209 / 1390 / 946 per run). All 12 per-block input-hash
cross-checks OK. scripts_rev `94e94c5f`.

- Run-level mean log-ratios (C/A): **+0.3216 / +0.3590 / +0.9822 / +0.4134 / +0.4897 / +0.3819**
- Point estimate exp(mean) = **1.6344×**
- Paired-bootstrap 95% CI: exp([+0.3596, +0.6962]) = **[1.4328, 2.0062]×**
- Rule (frozen): PASS iff CI lower bound ≥ 1.50× → **PRIMARY: FAIL** (1.4328 < 1.50)
- Continuity reference (Protocol-Lock 1.20×, reported, non-deciding): **PASS**
- Secondary gates (each ≤ 1.05×): pooled P95 TPOT ratio C/A = **0.6700** (221.96 ms vs
  331.29 ms), pooled P95 TTFT ratio = **0.1578** (1.597 s vs 10.116 s) — clean.

The tuned arm is faster than BF16 by a sealed margin and dramatically better in the
tail; it is not *proven* faster than 1.50×. The frozen rule fires as written.

## 5. What this means, stated precisely

- **Supported:** the attention-exempt FP8 configuration restores quality neutrality
  on the frozen 150 under a three-judge panel including the original red-dot judge,
  and it beats BF16 with a sealed CI lower bound of 1.4328× at the Pilot 002
  operating point, with far better tail latency.
- **Not demonstrated:** throughput superiority at the 1.50× level. The interval
  [1.4328, 2.0062] straddles the bar; the honest statement is "1.50× not
  demonstrated," nothing stronger in either direction.
- **Not claimed:** that the exemption's throughput cost has a precisely measured
  size (it was not isolated as a single variable against Pilot 002's stock FP8 in
  this design), or that 1.50× is unreachable for this recipe family.

## 6. Post-hoc exploratory analysis (descriptive; NOT part of the verdict)

Computed after the sealed verdict, on public archive data only:

1. **The heaviest slice tells the cost story.** Run 3 (the busiest hour pair, the
   same slice where Pilot 002's BF16 arm collapsed) shows log-ratio +0.9822 (≈2.67×)
   for the tuned arm, versus +2.2380 (≈20×) for stock FP8 in Pilot 002. Hypothesis,
   untested: exempting attention projections from FP8 leaves more compute/memory
   pressure exactly where the capacity knee bites, so the tuned arm escapes the
   saturation collapse less completely than full FP8 did.
2. **The five lighter slices are consistent and modest:** log-ratios +0.32 to +0.49
   (≈1.38–1.63×), versus Pilot 002 stock FP8's +0.45 to +0.72 on the same slices.
3. **Cross-pilot context:** Pilot 002's stock FP8 CI lower bound was 1.6691× — it
   would have met this pilot's 1.50× bar. The repair bought quality back at a real
   throughput cost; the size of that cost is bounded by these two pilots but not
   isolated within either.
4. **Judge scales differ; differences don't.** glm-4.6 scores both arms ~2.5 points
   lower in absolute terms than 0324; within-judge differencing absorbs this by
   construction (same lesson as Pilot 002's judge-drift analysis).

These items shape the next hypothesis; they decide nothing.

## 7. Governance chain and incidents

- PREREG-ADDENDUM-02 frozen 2026-10-08, published (commit `7866ed2`) before the first
  stage-07 execution. Dual gates, seeds, arms, panel rules, and thresholds are in
  that document; nothing in it was edited after execution began.
- Execution-time disclosures, each a separate addendum with old→new script hashes
  (ADDENDUM-02's frozen table itself was never edited):
  - **ADDENDUM-03** (`e1dac39`): stage-07 checkpoint-builder defects (builder API
    signature mismatch, calibration-dataset type, exit-code masking) — patched before
    any tuning data existed.
  - **ADDENDUM-04** (`ddd58e7`): dependency alignment (transformers pinned to 5.10.4)
    and stdout-capture contamination of a shell variable carrying the checkpoint path.
  - **ADDENDUM-05** (`4cf2b5c`): a heredoc environment-variable omission (masked by
    bash command-substitution semantics) and removal of the stdout capture contract
    entirely; includes a disclosed custody gap — two local build-completion entries
    are missing from the pod-local recipe log and were not backfilled (append-only
    discipline).
  - **ADDENDUM-06** (`6d464e8`): one-line judge-call fix — glm-4.6 is a
    reasoning-generating model; `reasoning: exclude` hides but does not disable
    reasoning, burning the token budget to null content. Patched at the zero-judgment
    point; panel rules, prompts, seeds, thresholds unchanged.
- The family-diversity clause fired twice as designed (stage 08 REFUSED to seat an
  all-DeepSeek panel while glm-4.6 was unreachable) — the gate refusing to judge is
  part of the evidence.
- After a pod wipe, the six formal measurement plans were regenerated via the
  pre-built `--rebuild` path; all plan hashes are identical to the sealed stage-01
  manifest (`0c0fcf14…` chain). A terminal disconnect interrupted one screening
  generation mid-run; per-request resume re-executed only missing rows against
  append-only logs. No data was lost or duplicated in either incident.
- Correction to ADDENDUM-02 §1: it states the Pilot 002 red dot as −0.16; the sealed
  stage-05 value is **−0.127**. A drafting slip in the addendum's preamble; no rule,
  threshold, or outcome refers to that number.
- Log chain (public `effiq/pilot-logs`): stage 07 → `4bd295a`, stage 08 → `3e0d66e`,
  stage 09 + trace-regeneration record → `6160ed4`. Script hashes at execution:
  07 `106c10cd…0719`, 08 `d86b9bab…e5a`, 09 `fbb085c6…81dd1` (repo revisions
  `5762be1b` / `318813e6` / `94e94c5f`).
- All three verdicts are byte-reproducible from the public archive alone
  (see REPRODUCE.md); each was re-verified from a fresh clone before publication.

## 8. What happens next (pre-registered, ADDENDUM-02 §5)

This FAIL is type 丙 (quality green, performance bar missed): publish in full — this
document — and the quality-green configuration is eligible to ship as a dual-config
product option: **tuned a4** (quality-repaired, 1.6344× point estimate, CI lower
1.4328×) alongside **stock FP8** (Pilot 002: 2.3279× point estimate, with the
disclosed red dot). A retry of the 1.50× bar requires the resurrection clause: a new
hypothesis, a new pre-registration, and root-cause evidence — a single FAIL is never
project death, and the lever-space map above (including its red cells) is published
either way.

## 9. Related work

- **Pareto Atlas** (arXiv:2609.17863), **Cascade** (arXiv:2608.06557),
  **SPEED-Bench** (arXiv:2604.09557): see Pilot 002 VERDICT.md §7 — the positioning
  is unchanged. Sensitive-layer exemption and calibration-domain matching are
  standard quantization craft (e.g., SmoothQuant-style smoothing); the lever itself
  is not the claim. The claim is the shape of the evidence: a pre-registered
  screening → single-shot-confirm pipeline, a mandatory-seat judge panel, dual
  sealed gates, and a FAIL published with everything attached.

## 10. Scope and limitations

Single model (Qwen2.5-14B), single GPU class (L40S), single serving stack (vLLM
0.31.0), one operating point on one trace family; payload contents are synthetic
fillers shaped to trace token counts; quality judged by LLM judges on a 150-item
frozen set (judge noise characterized in Pilot 002 §5 and §6.4 above); the recipe
body of the winning arm is gate-layer material — published as sha256, verifiable
against any later disclosure, not public today. Nothing in this document should be
read as a claim about other models, GPUs, quantizers, or operating points — and
nothing in it upgrades the FAIL.

## 11. Hash manifest (short form)

| artifact | sha256 (prefix) |
|---|---|
| arms-manifest.json (public arm registry) | `5f1a1972…e9387` |
| stage-07 screening script (as executed) | `106c10cd…0719` |
| stage-08 confirm script (as executed) | `d86b9bab…e5a` |
| stage-09 perf script (as executed) | `fbb085c6…81dd1` |
| frozen_set.jsonl (from Pilot 001/002) | `728b2f83…5cf7d` |
| screening_set.jsonl (40 items) | `d0b3da96…9b5ab` |
| winner recipe (a4-exempt-attn) | `5065e67e…df8` |
| winner checkpoint (×3 byte-identical builds) | `539cee71…c420` |
| stage-08 gen_C / judge_raw_c | `38b12c47…9bdf` / `ed7ebe8e…a9e5` |
| verdict_s / verdict_c / verdict_t | in archive `2026-10-09/{07-lever-screening,08-red-dot-confirm,09-tuned-perf}/run_1` |

Full hashes live in the public archive; every number in this document is recomputed
by the `--verify` entry points described in REPRODUCE.md.
