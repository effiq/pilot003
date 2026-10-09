# PREREG-ADDENDUM-02 — Pilot 003: Red-Dot Repair (FP8 Lever Screening + Single-Shot Confirmation)

**Status:** FROZEN BEFORE EXECUTION — 2026-10-08
**Parent documents:** Pilot 002 preregistration + PREREG-ADDENDUM-01 (judge mechanics), Effiq Protocol Lock
**Scope:** This addendum freezes the design, thresholds, seeds, and scripts of Pilot 003 before any GPU run. Nothing below may be edited after the first stage-07 execution starts; changes require a new addendum (ADDENDUM-03).

---

## 1. Purpose

Pilot 002 measured stock FP8 dynamic quantization (`--quantization fp8`) on Qwen2.5-14B-Instruct at 1.20× throughput with a **published quality red dot**: the original judge (deepseek-chat-v3-0324) scored the FP8 arm −0.16 on the clarity axis, breaching the −0.1 tolerance.

Pilot 003 attempts to **repair that red dot** by tuning the quantization configuration, and to **improve the performance ratio from 1.20× to a commercially meaningful level**, under the same measurement discipline.

Pilot 003 is an optimization pilot, not a benchmark. Its claims gate is therefore stricter, not looser, than Pilot 002's.

## 2. Frozen design

### 2.1 Two-phase structure (anti-p-hacking)

- **Phase 1 — screening (stage 07):** 40 screening items, **disjoint** from the frozen 150 (hard gate: zero prompt-sha256 overlap, asserted at build). A single cheap screening judge. Up to **8 arms in two waves**: wave 1 = 6 frozen arms (a1 control = exact Pilot 002 stage-05 arm-B config; a2–a5 = four single levers; a6 = all-lever combination); wave 2 = 2 adaptive combinations composed by a deterministic rule from the wave-1 ranking (merge(top1,top2) and merge(top1,top3); tie-break: overall delta, then arm_id).
- **Phase 2 — confirmation (stage 08):** the screening winner gets **exactly one** confirmation attempt on the sealed frozen-150 set with the full 3-judge panel. A miss is a published FAIL; a second attempt requires a new addendum.
- **Proceed rule:** winner screening clarity delta ≥ −0.05 (half the tolerance, declared transfer margin). Otherwise SCREENING-EXHAUSTED — a legitimate published FAIL.

### 2.2 Dual gates (BOTH required for PILOT 003 PASS)

- **Quality gate (stage 08):** 3-judge panel, worst-judge rule, per-judge overall AND per-axis deltas ≥ −0.1 on the frozen 150. Amendment-01 judge mechanics (reasoning excluded, null content = error) apply unchanged.
- **Performance gate (stage 09):** paired bootstrap over 6 formal runs; **primary: CI lower bound ≥ 1.50×** (C/A per-request throughput, run-level mean log-ratios). The Protocol-Lock continuity threshold 1.20× is computed and reported but does not decide. **Secondary:** pooled P95 TPOT and TTFT non-inferiority, 5% tolerance. **No straddle extension is pre-registered** — n = 6 decides.

### 2.3 Panel rule (stage 08)

- PANEL_SIZE = 3. **Seat 1 is mandatory: deepseek-chat-v3-0324**, the original red-dot judge. Rationale: a repair that benches the referee is not a repair (judge-shopping clause). If 0324 is unreachable: REFUSED, owner decision required.
- Seats 2–3: first two reachable of [z-ai/glm-4.6, deepseek/deepseek-v3.1-terminus, deepseek/deepseek-chat-v3.1], probed in order with Amendment-01 mechanics.
- **Family diversity:** the frozen panel must span ≥ 2 vendor families, else REFUSED.
- Screening judge (stage 07): cheapest-first probe of [deepseek-chat-v3.1, deepseek-v3.1-terminus, z-ai/glm-4.6]; the selection is pinned to `screening_judge.txt` and is sticky on resume (mismatch → REFUSED).

### 2.4 Lever classes under test (per-arm recipes are gate-layer material, see §4)

- a1-control: FP8 dynamic, exactly Pilot 002 stage-05 arm B (control).
- a2-smooth: activation smoothing (SmoothQuant-style) + FP8 dynamic.
- a3-calib-static: FP8 static scales from domain-matched calibration (256 texts).
- a4-exempt-attn: FP8 dynamic with attention projections exempted.
- a5-exempt-down: FP8 dynamic with MLP down-projection exempted.
- a6-all: static scales + smoothing + both exemptions.
- a7-w2 / a8-w2: deterministic merges per §2.1.

The measured artifact is the built checkpoint (full-tree sha256), not the builder. Builder (llmcompressor) version is recorded as provenance. Checkpoints are built → served → measured → **deleted** (disk discipline: peak = base weights + one checkpoint); rebuilds after pod wipe are recorded with their new hash and any divergence from the screening build is disclosed in the verdict as a declared deviation.

### 2.5 Frozen seeds

| Constant | Value | Used for |
|---|---|---|
| SCREEN_SEED | 20261013 | 40-item screening set |
| BLIND_SEED_SCR | 20261014 | per-(arm,item) blind bit, screening |
| CALIB_SEED | 20261015 | 256 calibration texts |
| BOOT_SEED | 20261012 | quality bootstrap CIs |
| BOOT_SEED (perf) | 20262002 | performance bootstrap (unchanged from Pilot 002 stage 04) |
| RUN_SEED_BASE | 20264000 | stage-09 formal runs (distinct from Pilot 002's 20263000) |
| FILLER_SEED | 20261010 | stage-09 filler token stream (same as Pilot 002 stage 01) |

### 2.6 Frozen anchors (carried from sealed Pilot 002 archives)

- frozen_set.jsonl sha256: `728b2f8354701a301467afaf52d643d12a679af5c41542bb1701634e4235cf7d`
- gen_A.jsonl (BF16 reference) sha256: `16df35ccad32cc60a5785ce87fa96e325487b66ec3000e3fa04e6479b886c8cd`
- blind_map.jsonl sha256: `684aea8dcc33ce4f88d9aa8644007cdb8ace0e4ff331a124b8c62fe1c7e76392`
- Stage-09 reuses Pilot 002 stage-01 formal plans (anchor-checked per pair against `plans_manifest.json` merged_sha256) and the stage-02 `chosen.json` operating point (r = 1/256, C = 4; the fallback disclosure is carried into every summary if set).

### 2.7 Model and engine boundary (unchanged)

Qwen/Qwen2.5-14B-Instruct @ revision `cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8`, vLLM 0.31.0, single L40S 48GB, prefix caching OFF. Any change = new pilot.

## 3. Frozen artifacts (sha256)

| Artifact | sha256 |
|---|---|
| arms-manifest.json (public arm registry) | `5f1a1972e0ba628ebb5f4df29bc017c64ed1b6eb5e6fdaddb409f44c24eb9387` |
| stages/07-lever-screening.sh | `fc2d0e7ce13a45f8c1a0fd20bf56a4b5edfc7d5353f5d77b856fe4ec5b7896ba` |
| stages/08-red-dot-confirm.sh | `1593640411bc36313c301540a7868941db6069172afc31738f4db3191b7d62bb` |
| stages/09-tuned-perf.sh | `83d2bd9f3dfacd66f4bdc1d0379fb4f5a1d5acbdf89478282167dbddd6e0c3f0` |
| tonight.sh (pod runner) | `254abadf2a29d82903f8609ed6448ee4929358f30e30de33c2507602457bcc4e` |

Per-recipe sha256 values for the six wave-1 arms are frozen inside arms-manifest.json (`a1 de55c8bc…`, `a2 0785c061…`, `a3 9c95595c…`, `a4 5065e67e…`, `a5 c594b379…`, `a6 87b37e6e…` — full values in the manifest). Wave-2 recipe hashes are composed at runtime and recorded in the run archive before use.

## 4. Three-layer disclosure (constitutional clause 6-A, first application)

- **Public layer (always public):** this addendum, arms-manifest.json, all stage scripts, all run archives (raw JSONL, verdicts, hashes), the winner's lever-class labels and recipe sha256, checkpoint hashes.
- **Gate layer (existence public, content gate-layer):** the full quantization recipe bodies. Run archives carry their sha256; the bodies themselves live only on the pod (`~/pilot-env/arms-recipes.json`, chmod 600, never committed) and in the pod-local `recipes-local.jsonl` (never pushed). The hash chain makes any later disclosure verifiable: what we publish later can be proven identical to what was executed tonight.
- **Private layer (never public):** API keys, tokens, pricing/contract intelligence per the security constitution.

The time-delay principle: the map is free; the recipe is the shop. Publishing hashes tonight and bodies later is not ambiguity — the hash pins the body at execution time.

## 5. FAIL aftermath (pre-registered)

- **Type 甲 (screening-exhausted):** publish the FAIL with the full arm table; the screened lever space is marked red on the envelope map ("red is also map"). Lever deepening allowed; retry requires ADDENDUM-03.
- **Type 乙 (confirm miss):** publish; at most ONE retry via ADDENDUM-03.
- **Type 丙 (quality green but performance gate missed):** publish; the quality-green configuration may ship as a dual-config product option.
- **Death criterion:** 003 FAIL → retry FAIL → kill-page review. A single FAIL is never project death. Resurrection after a kill-page requires a new hypothesis + new preregistration + root-cause-fix evidence (no-appeal clause).

## 6. Predictions logged for calibration (before execution)

- Screening produces a PROCEED winner: ~70–80%.
- The single-shot dual-gate confirm passes: ~50–60%.

These are calibration points for the operator's judgment track record, not gates.

## 7. Verification

Every verdict file carries a one-command recomputation path:
`bash stages/<NN>-*.sh --verify <run_dir>` recomputes from raw archives and byte-compares (declared normalization: scripts_rev and machine-local paths only).

---

*Frozen by the operator (老板) and the AI engineering arm, 2026-10-08. First execution starts only after this file and the artifacts in §3 are uploaded to the public repo.*

**Revision history (pre-execution only):** 2026-10-09 — tonight.sh key-file name aligned to the Pilot 002 convention (`~/pilot-env/openrouter-key`); §3 hash updated. No design, threshold, seed, or arm content changed. No stage had been executed at the time of this revision.
