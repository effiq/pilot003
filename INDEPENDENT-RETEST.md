# Independent Verification & Re-Measurement — Pilot 003

This repository ships with its complete verdict evidence bundled under `retest/`.
You can check every published number yourself, with no account, no API key, and
no assistance from us.

Pilot 003's verdict is **FAIL** (quality gate passed; performance gate missed:
CI lower bound 1.4328× vs the pre-registered 1.50× bar). It is published in
full under the pre-registered FAIL-publication obligation.

**One honest limitation, stated up front.** Pilot 003 evaluated custom
quantization configurations ("arms") built from gate-layer recipe parameters.
The recipe parameter detail is withheld pending patent counsel review — this
is a confidentiality boundary, not an evidence gap: the complete raw
archives of every arm (screening, confirmation, performance) are bundled here,
the recipe and checkpoint custody hashes are published in
`arms-manifest.json` and the archives, and any future release of the artifacts
can be verified against those hashes. What this means for you:

- **Track 1 (audit / recompute)** covers the entire verdict, every arm, end to
  end — nothing is missing.
- **Track 2 (independent hardware re-measurement)** is currently available for
  the stock control arms only (BF16 baseline; vLLM built-in FP8). Re-building
  the custom-arm checkpoints requires the withheld parameters.

---

## Track 1 — audit / recompute (no GPU)

Requirements: Linux or macOS, `bash`, `python3` ≥ 3.10 with `numpy`. Nothing
else. No network beyond the initial clone. On Debian/Ubuntu (incl. WSL):
`sudo apt install -y python3-numpy`; elsewhere: `pip3 install numpy`.

If `~/effiq/pilot003` already exists from an older clone, move it aside first:
`mv ~/effiq/pilot003 ~/effiq/pilot003-old` (and `rm -f ~/effiq/pilot-logs`).

```bash
mkdir -p ~/effiq && cd ~/effiq
git clone https://github.com/effiq/pilot003.git
ln -s "$HOME/effiq/pilot003/retest/pilot-logs" ~/effiq/pilot-logs
```

(The scripts also honor a `LOGS_DIR` environment variable pointing at the
bundled archive root, if you prefer not to symlink.)

### Screening (stage 07)

```bash
bash ~/effiq/pilot003/stages/07-lever-screening.sh --verify ~/effiq/pilot-logs/2026-10-09/07-lever-screening/run_1
```

Expected ending: `VERIFY: verdict_s.txt byte-identical` + `VERIFY: ALL CHECKS PASSED`.

### Confirmation (stage 08)

```bash
bash ~/effiq/pilot003/stages/08-red-dot-confirm.sh --verify ~/effiq/pilot-logs/2026-10-09/08-red-dot-confirm/run_1
```

Expected ending: `VERIFY: verdict_c.txt / verdict_c.json identical` + `VERIFY: ALL CHECKS PASSED`.

### Performance verdict (stage 09)

```bash
bash ~/effiq/pilot003/stages/09-tuned-perf.sh --verify ~/effiq/pilot-logs/2026-10-09/09-tuned-perf/run_1
```

Expected: recomputed run-level log-ratios (+0.3216 / +0.3590 / +0.9822 /
+0.4134 / +0.4897 / +0.3819), point estimate 1.6344×, paired-bootstrap 95% CI
[1.4328, 2.0062] (seed 20262002, 100,000 resamples), lower bound below the
frozen 1.50× bar → FAIL, ending with:

```
VERIFY: verdict_t.txt / verdict_t.json identical (numbers byte-exact; declared provenance normalized)
VERIFY: ALL CHECKS PASSED
```

### Integrity

```bash
cd ~/effiq/pilot003/retest && sha256sum -c MANIFEST.sha256
```

---

## Track 2 — independent re-measurement (partial, rented GPU)

Re-runnable today: the BF16 baseline arm and the stock FP8 control arm
(`a1-control` = vLLM built-in `--quantization fp8`, serving flags in the
bundled `server_argv_*.txt` files), on one NVIDIA L40S with the pinned stack
in `retest/environment.lock`. The trace-derived workload regenerates
deterministically from the public Azure trace via Pilot 002's stage-01 (seed
20261010); the operating point (r = 1/256, C = 4) is frozen in the bundled
`2026-10-06/02-calibration/run_1/chosen.json`.

Not currently re-runnable: checkpoint construction for the custom arms
(gate-layer parameters withheld as stated above). The published custody hashes
(`recipes_executed.jsonl`, `checkpoints.jsonl`, `checkpoint_perf.json`) let you
verify any future artifact release against the original measurement chain.
