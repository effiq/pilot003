# PREREG-ADDENDUM-03 — Engineering Patch Disclosure: checkpoint-build call sites (stages 07/08/09)

**Date:** 2026-10-09 (UTC)
**Status:** Engineering patch disclosed after execution start. No design, threshold, seed, arm, or recipe content changed. The frozen design of ADDENDUM-02 remains the governing protocol; this addendum supersedes only the §3 script hashes of ADDENDUM-02.

## 1. What happened

Stage 07 execution started 2026-10-09 ~05:37 UTC. The reference arm (R, BF16) and control arm (a1, vLLM dynamic FP8 on the pinned base model) completed generation on the 40-item screening set. The first checkpoint-build arm (a2-smooth) failed at builder invocation: `llmcompressor.entrypoints.oneshot()` rejected the keyword `revision` (`ValueError: Some keys are not used by the HfArgumentParser: ['revision']`). The checkpoint was never created; the subsequent server start then failed on the missing directory.

## 2. Defects and fixes (all inside checkpoint-build code paths)

1. **Keyword name.** The scripts called `oneshot(model=..., revision=MODEL_REV, ...)`. llmcompressor 0.12.0 (the builder pinned for this pilot; recorded as provenance) declares the field as `model_revision`. Fix: `revision=` → `model_revision=` at all four call sites (07 ×1, 08 ×2, 09 ×1). The pinned base-model revision `cf98f3b3…` is still enforced — through the builder's correct parameter.
2. **Calibration dataset type.** The scripts passed a raw Python list of dicts as `dataset=`. llmcompressor 0.12.0 accepts a dataset name (`str`), a `datasets.Dataset`/`DatasetDict`, or a `DataLoader` — a raw list is not a supported input type and would have failed downstream of the keyword fix. Fix: wrap with `datasets.Dataset.from_list(...)` at the same four call sites. Calibration content is byte-identical (same 256 texts, same order, same frozen seed 20261015; `calibration_texts_sha256=f7020a78…` unchanged and re-asserted on resume).
3. **Error propagation (07 only).** In stage 07 the build runs inside a command substitution whose trailing `echo` masked a non-zero builder exit, letting execution continue to server start with a missing checkpoint. Fix: after the builder returns, the function now asserts `<ckpt>/config.json` exists and returns non-zero otherwise, so the existing `die "checkpoint build failed"` guard fires correctly. Stages 08/09 run their builders at top level under `set -euo pipefail` and did not have this defect.

## 3. Root cause

The pre-execution sandbox suite exercised the build path with a mock builder (`STAGE07_MOCK_BUILD=1`) and therefore never called the real `oneshot()` API. The mock validated pipeline logic but not the builder's parameter signature or input types. Corrective action for future pilots: builder-facing call sites must be smoke-tested against the real builder package (a minimal one-shot on a small model) before freeze, or the mock must assert kwargs against the real signature.

## 4. Impact statement

- **No measured data is affected.** At patch time, zero checkpoints had been built for any arm (a2–a6, wave 2). The completed arms R and a1 serve the pinned base model directly and never enter the build path; their generation artifacts stand.
- **No design content changed.** Arms, recipes, seeds, thresholds, gates, judge panel rules, and the anti-p-hacking protocol are untouched. `arms-manifest.json` (`5f1a1972…`) is unchanged; per-recipe hashes are unchanged.
- Execution resumed in the same run directory under the deterministic resume design; the screening set (`d0b3da96…`) and calibration texts (`f7020a78…`) were re-asserted identical on resume.
- The executing script revision is recorded in the run archive (`scripts_rev`, git short hash) as usual, so the exact patched bytes that produced every artifact are recoverable from the repository history.

## 5. Updated artifact hashes (supersedes ADDENDUM-02 §3 for these three rows)

| Artifact | previous sha256 (frozen, pre-execution) | patched sha256 (this addendum) |
|---|---|---|
| stages/07-lever-screening.sh | `fc2d0e7ce13a45f8c1a0fd20bf56a4b5edfc7d5353f5d77b856fe4ec5b7896ba` | `b49f82df02b85fb6df6b188b47028ddf4849dfdf2a59d4bf096d77f68d2c36c3` |
| stages/08-red-dot-confirm.sh | `1593640411bc36313c301540a7868941db6069172afc31738f4db3191b7d62bb` | `f6f858aea7cbc324ebc1a8a93d348fd3c66f5e6db5541966a49c0edb7bce3f21` |
| stages/09-tuned-perf.sh | `83d2bd9f3dfacd66f4bdc1d0379fb4f5a1d5acbdf89478282167dbddd6e0c3f0` | `fbb085c6f788ca30ac2a04fd9b7f98800e7495202b7d330c0c4b05b373781dd1` |

All other ADDENDUM-02 §3 hashes (tonight.sh `254abadf…`, arms-manifest.json `5f1a1972…`, frozen-set/gen_A/blind_map anchors) are unchanged.

## 6. Cost disclosure

The failed attempts consumed GPU time without producing artifacts (environment repair, a disk-headroom expansion of the pod from 60 GB to 150 GB, and the two failed a2 build invocations). Figures are logged in the internal ledger per standing practice; the public cost summary in the final verdict will cover the producing runs.
