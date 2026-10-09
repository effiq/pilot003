# Pilot 003 — Reproduction Guide

Every verdict number in VERDICT.md is recomputed from the public log archive alone —
no GPU, no network services, no API keys. If you find a mismatch, that is a
reportable event; please open an issue.

## 0. Get the archive and the scripts

```bash
git clone https://github.com/effiq/pilot-logs.git     # all raw data + verdicts
git clone https://github.com/effiq/pilot003.git       # pre-registration + stage scripts
```

Requires: `bash`, `python3` (3.10+), `numpy` (`pip install numpy`). Nothing else.

## 1. Screening verdict (stage 07)

```bash
bash pilot003/stages/07-lever-screening.sh --verify pilot-logs/2026-10-09/07-lever-screening/run_1
```

Expected: the full eight-arm table (clarity / overall deltas), the control-arm red-dot
reproduction (a1-control −0.250), the winner selection (a4-exempt-attn), and the
PROCEED outcome, recomputed from the archived screening logs, ending with:

```
VERIFY: verdict_s.txt byte-identical (declared provenance normalized)
VERIFY: ALL CHECKS PASSED
```

## 2. Quality gate (stage 08)

```bash
bash pilot003/stages/08-red-dot-confirm.sh --verify pilot-logs/2026-10-09/08-red-dot-confirm/run_1
```

Expected: all per-judge per-axis deltas for the three-judge panel (0324 / glm-4.6 /
v3.1-terminus), the worst-judge PASS line, the frozen-anchor assertions against the
sealed Pilot 002 stage-05 archive (frozen_set `728b2f83…`, gen_A `16df35cc…`,
blind_map `684aea8d…`), ending with:

```
VERIFY: verdict_c.txt / verdict_c.json identical (declared provenance normalized)
VERIFY: ALL CHECKS PASSED
```

The verify path never calls a judge model; it re-derives the verdict from the
archived judge responses.

## 3. Performance gate (stage 09)

```bash
LOGS_DIR=$(pwd)/pilot-logs bash pilot003/stages/09-tuned-perf.sh --verify pilot-logs/2026-10-09/09-tuned-perf/run_1
```

Expected: recomputation of the six run-level log-ratios, the point estimate
(1.6344×), the paired-bootstrap 95% CI ([1.4328, 2.0062]×, seed 20262002, 100,000
resamples), both secondary P95 gates, the continuity line vs 1.20×, and all 12
per-block input-hash cross-checks from the raw archives, ending with:

```
VERIFY: verdict_t.txt / verdict_t.json identical (numbers byte-exact; declared provenance normalized)
VERIFY: ALL CHECKS PASSED
```

`LOGS_DIR` tells the script where the archive root is (the operating point is frozen
inside Pilot 002's stage-02 `chosen.json`, and the stage-08 winner record is
anchor-checked — both live in the archive, outside the stage-09 run directory).
Declared normalization (only machine-local provenance fields are excluded from
byte-comparison; every number is byte-compared): the absolute archive path in the
header, and `scripts_rev` (resolvable only where a pilot003 git checkout exists).

## 4. Anchor hashes worth checking first

```bash
sha256sum pilot-logs/2026-10-09/08-red-dot-confirm/run_1/frozen_set.jsonl
# 728b2f8354701a301467afaf52d643d12a679af5c41542bb1701634e4235cf7d
```

The frozen evaluation set is reused from Pilot 001/002 by hash; stages refuse to run
against any input whose hash differs from the pre-registered anchors. The winning
checkpoint is deleted per its lifecycle; its full-tree hash (`539cee71…c420`,
checkpoint_perf.json) plus the recipe hash (`5065e67e…df8`) pin what was measured.

## 5. What reproduction does and does not cover

- Covered: every statistic and every verdict line of all three stages, from archived
  raw logs.
- Not covered (by design): re-running the serving measurement itself (needs an L40S,
  ~3.5 h, and the frozen plan files whose hashes are anchored in the archive —
  regenerable via `pilot002/stages/01-trace-pipeline.sh --rebuild`, hash-checked
  against the sealed stage-01 manifest), re-calling the judge endpoints (judge
  outputs are archived verbatim), and rebuilding the checkpoint (builder recipe body
  is gate-layer material, hash-pinned per ADDENDUM-02 §4).
