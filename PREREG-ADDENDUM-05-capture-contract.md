# PREREG-ADDENDUM-05 — Stage 07 Patch 3: builder output-channel contract removed

**Status:** disclosed before the run resumes. Zero measured data affected. Design, thresholds, seeds, arms, recipes, and manifest unchanged. Supersedes the stage-07 hash recorded in PREREG-ADDENDUM-04.

## 1. What happened (2026-10-09 UTC, execution log)

- 08:26:02 → 08:33:44 — the `a3-calib-static` checkpoint build **completed successfully**: 336/336 layers compressed, model shards written, dispatch finished; tree hash computed; public custody entries appended to `recipes.jsonl` and `checkpoints.jsonl`.
- Immediately after the save, the build python raised `KeyError: 'LOCAL_RECIPE_LOG'` in its custody tail. Root cause: the shell invoked the build heredoc with an explicit inline environment list (`RJSON CKPT_DIR CALIB_JSONL MODEL MODEL_REV RECIPE_LOG CKPT_LOG`) that **omitted `LOCAL_RECIPE_LOG`**, a plain non-exported shell variable. The defect was latent since the frozen version.
- The crash was masked by bash semantics: `errexit` is not inherited inside `$( ... )` command substitution, so the non-zero python exit inside `cdir="$(build_checkpoint "$arm")"` did not abort the run. The completeness guard (`config.json` present) passed and the function returned 0. The same masked crash had occurred for `a2-smooth` under patch 1 — its checkpoint was likewise fully written before the crash, and it subsequently served healthy and completed 40/40 generations.
- Server start then failed: the captured path variable contained builder log lines. **llmcompressor 0.12.0 attaches its loguru sink to `sys.stdout`** (`llmcompressor/logger.py:110`, verified against the distributed wheel). Patch 2 had moved our own prints to stderr; the third-party library's stdout chatter remained in the capture channel, so vLLM received a multi-line garbage path and died at startup. Stage exited rc=1.

## 2. Fixes in patch 3

1. **Env pass-through:** `LOCAL_RECIPE_LOG` added to the build heredoc's inline environment list.
2. **Output-channel contract removed (the structural fix):** `build_checkpoint` no longer prints the checkpoint path to stdout and is no longer invoked via `$( ... )`. Callers construct the deterministic path `$CKPT_ROOT/$arm`. Base-model / reuse / mock paths print to stderr only. No library can pollute a capture that no longer exists.
3. **Completeness guard strengthened:** requires `config.json` **and** at least one `.safetensors` shard (previously `config.json` only).
4. **Same-class sweep:** a static audit enumerated every hard `os.environ[...]` read in every python heredoc across stages 07/08/09 and checked each against the variables passed inline or exported. This was the **only** instance in all three scripts; stages 08 and 09 are clean on this defect class.

## 3. Data integrity statement

- **Zero measured data affected.** Both failures occurred after the a3 build completed and before any a3 generation; R / a1-control / a2-smooth generations stand untouched. Screening set (`d0b3da96…9b5ab`) and calibration texts (`f7020a78…c8ab8`) hashes unchanged; arms manifest `5f1a1972…9387` unchanged.
- **Checkpoints are valid:** `a2-smooth` — empirically proven (served healthy in 80 s, generated 40/40, then deleted per the build→serve→delete lifecycle); `a3-calib-static` — identical code path, crash occurred after the complete save, guard passed, and the checkpoint will be **reused** on resume (no rebuild).
- **Custody gap, disclosed not repaired:** the pod-local `recipes-local.jsonl` is missing the build-completion entries for `a2-smooth` and `a3-calib-static`. The public-side `checkpoints.jsonl` / `recipes.jsonl` build entries (including `checkpoint_sha256`) are intact; full recipe bodies remain in `arms-recipes.json` (pod-local, never committed) and in each checkpoint's `recipe.yaml`. Append-only logs are not rewritten — this note is the record of the gap.

## 4. Script hashes

| file | previous (ADDENDUM-04) | current |
|---|---|---|
| stages/07-lever-screening.sh | `25422ee35788783810eade125e8d6a2e5cccebd228982e6181fc635391aaeeb9` | **`106c10cd13681829081b6a2e36d581378c3c40191ab750a9899e26ae10030719`** |
| stages/08-red-dot-confirm.sh | `f6f858aea7cbc324ebc1a8a93d348fd3c66f5e6db5541966a49c0edb7bce3f21` | unchanged |
| stages/09-tuned-perf.sh | `fbb085c6f788ca30ac2a04fd9b7f98800e7495202b7d330c0c4b05b373781dd1` | unchanged |

## 5. Root cause and standing rules adopted

The chain behind all three a2/a3 failures: sandbox mock builds never exercised the real oneshot API, its stdout channel, or its environment-variable surface; and two bash behaviors masked defects — `$( )` capture of a chatty function, and `errexit` not inherited in substitution subshells. Rules now adopted at the execution layer:

1. Functions that run third-party build tooling must not return values via stdout; paths are deterministic and constructed by callers.
2. Every python heredoc's hard environment reads must be enumerated and explicitly passed; the audit tool exists and runs over all stage scripts before freeze/ignition.
3. Mocks must replicate the real callee's signature, output channels, and environment-variable surface.

## 6. Cost note

a3 build ≈ 7.7 GPU-minutes — the artifact is retained and reused, so it is not waste. Failed server start ≈ seconds. Diagnosis/repair idle ≈ 40 min of pod time at $1.11/h. As before, the public cost summary counts productive runs only.
