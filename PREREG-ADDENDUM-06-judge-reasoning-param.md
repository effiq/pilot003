# PREREG-ADDENDUM-06 — Stage 08 judge-call reasoning parameter fix

**Status:** disclosed before any judgment data exists. Zero judgments recorded at patch time — the failure occurred at panel formation, which precedes all scoring. Panel rules, candidate list, judge prompts, blind map reuse, seeds, thresholds, and the frozen set are unchanged.

## 1. What happened (2026-10-09 UTC, execution log)

- Stage 08 completed generation on the frozen 150 and entered panel formation (`=== 6. panel judging ===`).
- Seat 1 (mandatory original red-dot judge `deepseek/deepseek-chat-v3-0324`) probed OK.
- Candidate `z-ai/glm-4.6` failed its liveness probe twice (11:37 and 11:43 UTC) with `ValueError: empty probe content`. The remaining reachable candidates were both DeepSeek family.
- The stage **REFUSED to form a single-family panel** (`panel families ['deepseek'] < 2 — family-diversity clause, ADDENDUM-02`) and exited rc=1. This refusal is the frozen guardrail operating as designed: a structurally biased panel must never produce a verdict.

## 2. Diagnosis (evidence: raw probe responses)

`glm-4.6` is a reasoning-generating model. The stage-06/08 judge mechanics pass `reasoning={"exclude": true}`, which **hides** reasoning from the response but does **not** stop its generation — hidden reasoning tokens still consume the `max_tokens` budget. The probe budget was `max_tokens=4`.

Empirical chain (pod-side probes against the live OpenRouter endpoint):

| probe | result |
|---|---|
| `max_tokens=16`, no reasoning param | `content:"\n"`, `reasoning` field populated, `finish_reason:"length"` |
| `max_tokens=512`, `exclude:true` | `content:null`, **512/512 tokens consumed**, `reasoning_tokens:540`, `finish_reason:"length"` |
| `max_tokens=32`, `enabled:false` | `content:"ok"`, `reasoning:null`, `completion_tokens:2`, `finish_reason:"stop"` |

Conclusion: with exclusion alone, even 512 tokens were entirely consumed by hidden reasoning on a trivial prompt; judgment prompts (long pairwise comparisons) made truncation-with-empty-content a near certainty. Disabling reasoning generation (`enabled:false`) makes the model answer directly.

## 3. Change (single functional line)

In `call_api` (used identically by the probe and by all judgment calls): `reasoning={"exclude": True}` → `reasoning={"enabled": False}`.

- **Effect on the DeepSeek judges: none** — they do not generate reasoning; the parameter is inert for them. Judgment budgets (`max_tokens` 4 probe / 1024 judgment) are unchanged.
- The declared stage-06/08 mechanics intent — "judgments are produced without reasoning traces" — is preserved and strengthened (previously: reasoning generated but hidden; now: not generated).
- Header comment updated to match. No other code touched.

## 4. What did NOT change

Panel size 3; mandatory original-judge seat; ≥2 vendor families clause; the declared candidate list and order; judge prompt byte-identity with stage 05; blind-map reuse by hash; all seeds; the quality gate (worst-judge overall delta ≥ −0.1); the frozen 150 (`728b2f83…`); the winner and its recipe sha (`5065e67e…`, verified against the manifest); all screening data and verdicts.

## 5. Script hashes

| file | previous | current |
|---|---|---|
| stages/08-red-dot-confirm.sh | `f6f858aea7cbc324ebc1a8a93d348fd3c66f5e6db5541966a49c0edb7bce3f21` | **`d86b9babf1d747ec9f44b182f117cfb65de6519151363e249b97f4fbe7158e5a`** |
| stages/07-lever-screening.sh | `106c10cd13681829081b6a2e36d581378c3c40191ab750a9899e26ae10030719` | unchanged |
| stages/09-tuned-perf.sh | `fbb085c6f788ca30ac2a04fd9b7f98800e7495202b7d330c0c4b05b373781dd1` | unchanged |

**Informational note:** stage 07's judge path carries the same `exclude` parameter. Stage 07 is COMPLETE; its screening judge was `deepseek-chat-v3-0324` (non-reasoning), so the parameter had no operational effect, and `--verify` is a pure log recompute that never calls the API. Stage 07 is therefore left byte-frozen.

## 6. Cost note

Three diagnostic probe calls ≈ $0.001 against the judge pool. Pod idle during diagnosis/patch ≈ 30 min at $1.11/h. The family-diversity REFUSED events consumed zero GPU and zero judge spend.
